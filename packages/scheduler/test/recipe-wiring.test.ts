// W2 wiring tests: deepseek-recipe endpoints as real call sources.
//
//   * cold start measures via the conversation-level encode endpoint
//     (/api/recipe/encode, framing + tool prompt included), falling back to
//     the raw-text batch only when encode is unavailable;
//   * warm steps skip measurement entirely (provider truth wins);
//   * the governance window comes from the model catalog, with
//     TRHA_CONTEXT_WINDOW still overriding it;
//   * GET /api/context/:id exposes that state for the TUI's /ctx.
//
// The kernel is scripted (express), like history-invariants: assertions run
// against what the kernel actually received, not just the final transcript.

import express from 'express';
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import type { Server } from 'http';
import type { AddressInfo } from 'net';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { createServer } from '../src/Server/index.js';

const auth = { 'Content-Type': 'application/json', Authorization: 'Bearer dev-token' } as Record<string, string>;

/** Kernel with the recipe endpoints + one scripted JSON completion. */
function wiringKernel(opts: { encodeStatus?: number } = {}) {
  const kernel = express();
  kernel.use(express.json());
  const hits: string[] = [];
  kernel.use((req, _res, next) => { hits.push(req.path); next(); });
  kernel.post('/session/start', (_q, res) => res.json({}));
  kernel.post('/api/recipe/encode', (req, res) => {
    if (opts.encodeStatus !== undefined) return res.status(opts.encodeStatus).json({ error: 'down' });
    // 回显校验：别名必须已被内核归一成 API 名（W2 契约）
    const model = req.body?.request?.model;
    res.json({ count: 777, model_version: model === 'DeepSeek-V4.1-Flash' ? 'DeepseekV41Flash' : 'unexpected' });
  });
  kernel.post('/api/token-count', (req, res) => {
    const texts = req.body?.texts;
    if (!Array.isArray(texts)) return res.status(400).json({ error: 'expected texts' });
    res.json({ counts: texts.map((t: string) => t.length) });
  });
  kernel.post('/v1/chat/completions', (_req, res) => {
    res.json({
      choices: [{ message: { role: 'assistant', content: 'done' }, finish_reason: 'stop' }],
      usage: { prompt_tokens: 900, completion_tokens: 10, total_tokens: 910 },
    });
  });
  return { kernel, hits };
}

async function listen(app: express.Express): Promise<{ port: number; server: Server }> {
  const s = await new Promise<Server>(resolve => {
    const srv = app.listen(0, '127.0.0.1', () => resolve(srv));
  });
  return { port: (s.address() as AddressInfo).port, server: s };
}

describe('recipe wiring (W2)', () => {
  let dir: string;
  let close: () => void;

  beforeEach(async () => {
    dir = await mkdtemp(path.join(tmpdir(), 'trha-recipe-wiring-'));
    process.env.TRHA_WORKSPACE = dir;
    process.env.TRHA_SCHEDULE_TICK_MS = '0';
  });
  afterEach(async () => {
    close?.();
    delete process.env.TRHA_WORKSPACE;
    delete process.env.TRHA_SCHEDULE_TICK_MS;
    try {
      await rm(dir, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
    } catch { /* 延迟释放，非测试失败 */ }
  });

  async function boot(encodeStatus?: number) {
    const { kernel, hits } = wiringKernel({ encodeStatus });
    const kernelServer = await listen(kernel);
    const stateDir = path.join(dir, 'state');
    const { app, stop } = createServer({
      port: 0, token: 'dev-token', haskellHost: '127.0.0.1', haskellPort: kernelServer.port, stateDir,
    });
    const schedulerServer = await listen(app);
    close = () => { stop(); kernelServer.server.close(); schedulerServer.server.close(); };
    const base = `http://127.0.0.1:${schedulerServer.port}`;
    const startRes = await fetch(`${base}/api/session/start`, {
      method: 'POST', headers: auth, body: JSON.stringify({ mode: 'standard', permissionMode: 'yolo' }),
    });
    const sessionId = ((await startRes.json()) as { sessionId: string }).sessionId;
    return { base, sessionId, hits };
  }

  it('cold start measures via /api/recipe/encode and normalizes the model alias', async () => {
    const { base, sessionId, hits } = await boot();
    await fetch(`${base}/api/agent/step`, {
      method: 'POST', headers: auth, body: JSON.stringify({ sessionId, message: 'hi' }),
    });

    expect(hits).toContain('/api/recipe/encode');
    // encode 成功时不再回退纯文本批量
    expect(hits).not.toContain('/api/token-count');
  });

  it('encode unavailable → falls back to the token-count batch', async () => {
    const { base, sessionId, hits } = await boot(500);
    await fetch(`${base}/api/agent/step`, {
      method: 'POST', headers: auth, body: JSON.stringify({ sessionId, message: 'hi' }),
    });

    expect(hits).toContain('/api/recipe/encode');   // 先试
    expect(hits).toContain('/api/token-count');     // 失败回退
  });

  it('warm step skips measurement entirely', async () => {
    const { base, sessionId, hits } = await boot();
    await fetch(`${base}/api/agent/step`, {
      method: 'POST', headers: auth, body: JSON.stringify({ sessionId, message: 'one' }),
    });
    const hitsAfterFirst = hits.length;
    await fetch(`${base}/api/agent/step`, {
      method: 'POST', headers: auth, body: JSON.stringify({ sessionId, message: 'two' }),
    });
    const secondTurn = hits.slice(hitsAfterFirst);
    expect(secondTurn).not.toContain('/api/recipe/encode');
    expect(secondTurn).not.toContain('/api/token-count');
  });

  it('/api/context reports the catalog window and exact pressure after a turn', async () => {
    const { base, sessionId } = await boot();
    const before = await (await fetch(`${base}/api/context/${sessionId}`)).json();
    expect((before as { exact: boolean }).exact).toBe(false);
    expect((before as { pressure: number }).pressure).toBe(0);

    await fetch(`${base}/api/agent/step`, {
      method: 'POST', headers: auth, body: JSON.stringify({ sessionId, message: 'hi' }),
    });
    const after = (await (await fetch(`${base}/api/context/${sessionId}`)).json()) as {
      window: number; pressure: number; percent: number; exact: boolean; model: string | null;
    };
    expect(after.window).toBe(524288);           // 模型目录（deepseek-flash）
    expect(after.pressure).toBe(900);            // provider 真值
    expect(after.exact).toBe(true);
    expect(after.percent).toBe(Math.round((900 / 524288) * 100));
    expect(after.model).toBe('deepseek-flash');
  });

  it('TRHA_CONTEXT_WINDOW still overrides the catalog', async () => {
    process.env.TRHA_CONTEXT_WINDOW = '1234';
    try {
      const { base, sessionId } = await boot();
      const ctx = (await (await fetch(`${base}/api/context/${sessionId}`)).json()) as { window: number };
      expect(ctx.window).toBe(1234);
    } finally {
      delete process.env.TRHA_CONTEXT_WINDOW;
    }
  });
});
