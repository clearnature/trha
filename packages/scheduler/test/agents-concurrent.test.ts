// Multiple agents at once, and stopping one mid-flight.
//
// The subagent tests so far used a single parent. Two parents running at the
// same time exercise the parts a single-threaded test cannot: per-session
// `inFlight` bookkeeping, child ids that must not leak between parents, and
// `interrupt_agent` landing while the target is genuinely busy.

import express from 'express';
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import type { Server } from 'http';
import type { AddressInfo } from 'net';
import { mkdtemp, readFile, readdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { createServer } from '../src/Server/index.js';

const auth = { 'Content-Type': 'application/json', Authorization: 'Bearer dev-token' } as Record<string, string>;

async function listen(app: express.Express): Promise<{ port: number; server: Server }> {
  const s = await new Promise<Server>(resolve => {
    const srv = app.listen(0, '127.0.0.1', () => resolve(srv));
  });
  return { port: (s.address() as AddressInfo).port, server: s };
}

const wait = (ms: number): Promise<void> => new Promise(r => setTimeout(r, ms));

/** Routes by the last user message; can delay the first call of a session. */
function routedKernel(opts: { slowFirst?: string; delayMs?: number } = {}) {
  const kernel = express();
  kernel.use(express.json());
  const slowSeen = new Set<string>();
  kernel.post('/session/start', (_q, res) => res.json({}));
  kernel.post('/v1/chat/completions', async (req, res) => {
    const msgs = req.body.messages as Array<{ role: string; content: string }>;
    // time-context 注入会插在真实 user 消息后面（带 source: 'time-context'），
    // 必须跳过，否则 script 永远匹配不上、tool_calls 不下发。
    const lastUser = [...msgs].reverse().find(m => m.role === 'user' && m.source !== 'time-context')?.content ?? '';
    const results = msgs.filter(m => m.role === 'tool').map(m => m.content);
    const toolCall = (name: string, args: Record<string, unknown>): void => {
      res.json({
        choices: [{
          message: {
            role: 'assistant', content: '',
            tool_calls: [{ id: `c-${name}-${Math.random().toString(36).slice(2, 7)}`, type: 'function', function: { name, arguments: JSON.stringify(args) } }],
          },
          finish_reason: 'tool_calls',
        }],
      });
    };

    if (opts.slowFirst && lastUser === opts.slowFirst && !slowSeen.has(opts.slowFirst)) {
      slowSeen.add(opts.slowFirst);
      await wait(opts.delayMs ?? 600);
      return toolCall('bash', { command: 'echo slow-done' });
    }
    // one tool call per conversation round: with results already present the
    // kernel answers, otherwise it would ask for the same tool forever
    if (lastUser.startsWith('work ') && results.length === 0) {
      const tag = lastUser.slice('work '.length);
      return toolCall('subagent', { task: `child-${tag}`, name: tag });
    }
    if (lastUser.startsWith('child-')) {
      return res.json({ choices: [{ message: { role: 'assistant', content: `echo: ${lastUser}`, finish_reason: 'stop' } }] });
    }
    if (lastUser.startsWith('interrupt ') && results.length === 0) {
      return toolCall('interrupt_agent', { id: lastUser.slice('interrupt '.length) });
    }
    res.json({ choices: [{ message: { role: 'assistant', content: results.join(' | '), finish_reason: 'stop' } }] });
  });
  return kernel;
}

describe('concurrent agents', () => {
  let dir: string;
  beforeEach(async () => {
    dir = await mkdtemp(path.join(tmpdir(), 'trha-conc-agents-'));
    process.env.TRHA_WORKSPACE = dir;
    process.env.TRHA_SCHEDULE_TICK_MS = '0';
  });
  afterEach(async () => {
    delete process.env.TRHA_WORKSPACE;
    delete process.env.TRHA_SCHEDULE_TICK_MS;
    await rm(dir, { recursive: true, force: true });
  });

  async function boot(k: express.Express) {
    const kernelServer = await listen(k);
    const stateDir = path.join(dir, 'state');
    const { app, stop } = createServer({
      port: 0, token: 'dev-token', haskellHost: '127.0.0.1', haskellPort: kernelServer.port, stateDir,
    });
    const schedulerServer = await listen(app);
    const base = `http://127.0.0.1:${schedulerServer.port}`;
    return { base, stateDir, close: () => { stop(); kernelServer.server.close(); schedulerServer.server.close(); } };
  }

  async function startSession(base: string): Promise<string> {
    const res = await fetch(`${base}/api/session/start`, {
      method: 'POST', headers: auth, body: JSON.stringify({ mode: 'standard', permissionMode: 'yolo' }),
    });
    return ((await res.json()) as { sessionId: string }).sessionId;
  }

  const step = (base: string, sessionId: string, message: string): Promise<Response> =>
    fetch(`${base}/api/agent/step`, {
      method: 'POST', headers: auth, body: JSON.stringify({ sessionId, message }),
    });

  it('two parents spawn their own children without crossing over', async () => {
    const app = await boot(routedKernel());
    const a = await startSession(app.base);
    const b = await startSession(app.base);

    const [ra, rb] = await Promise.all([
      step(app.base, a, 'work A'),
      step(app.base, b, 'work B'),
    ]);
    const [ba, bb] = await Promise.all([
      ra.json() as Promise<{ reply?: string }>,
      rb.json() as Promise<{ reply?: string }>,
    ]);

    // each parent saw its own child's answer, not the other's
    expect(ba.reply).toContain('echo: child-A');
    expect(ba.reply).not.toContain('child-B');
    expect(bb.reply).toContain('echo: child-B');
    expect(bb.reply).not.toContain('child-A');

    // children are distinct sessions with the right parents
    // child files are named from a sanitized id, so select by parentId
    const files = await readdir(app.stateDir);
    const all = await Promise.all(files
      .filter(f => f.endsWith('.json'))
      .map(async f => JSON.parse(await readFile(path.join(app.stateDir, f), 'utf8')) as { sessionId: string; parentId?: string }));
    const children = all.filter(r => typeof r.parentId === 'string');
    expect(children).toHaveLength(2);
    const parents = children.map(c => c.parentId).sort();
    expect(parents).toEqual([a, b].sort());

    app.close();
  });

  it('interrupt_agent stops a busy agent at the next round boundary', async () => {
    const app = await boot(routedKernel({ slowFirst: 'slow A', delayMs: 600 }));
    const a = await startSession(app.base);
    const b = await startSession(app.base);

    // A blocks inside its first model call
    const running = step(app.base, a, 'slow A');
    await wait(200);

    // B interrupts A while A is genuinely in flight
    const rb = await step(app.base, b, `interrupt ${a}`);
    const bodyB = (await rb.json()) as { reply?: string };
    expect(bodyB.reply).toMatch(/interrupted/);

    const ra = await running;
    const bodyA = (await ra.json()) as { reply?: string };
    // the loop stopped at the next boundary instead of continuing the tool loop
    expect(bodyA.reply).toBe('(interrupted)');

    app.close();
  });
});
