// P3 wiring: the kernel's causal-constraint verdict must reach the UI.
//
// The kernel attaches `trha_constraint` to its completion response (D-1). The
// scheduler is the UI's only door, so `/api/agent/step` must forward it --
// otherwise the frontend can never tell a constraint-protected reply from an
// unconstrained one.
//
// The stub kernel answers the streaming endpoint with plain JSON (no
// text/event-stream), which is exactly the "wire cannot stream" case: the
// bridge must fall back to the blocking call and still surface the verdict.

import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import type { Server } from 'node:http';
import { createServer as createHttpServer } from 'node:http';
import { createServer } from '../src/Server/index.js';

let sched: Server;
let kernel: Server;
let base = '';
const seen: { url?: string; body?: string }[] = [];
let kernelBody: unknown = {};

beforeEach(async () => {
  seen.length = 0;
  kernelBody = {
    choices: [{ message: { content: 'ok' } }],
    usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 },
    trha_constraint: {
      status: 'warn',
      t6: { polar: 3, toroidal: 7, berry: 11 },
      reach: true,
      edges: 2,
      reason: 'berry phase drift',
    },
  };

  kernel = createHttpServer((req, res) => {
    let body = '';
    req.on('data', c => { body += c; });
    req.on('end', () => {
      seen.push({ url: req.url, body });
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify(kernelBody));
    });
  });
  await new Promise<void>(resolve => kernel.listen(0, '127.0.0.1', () => resolve()));
  const kernelPort = (kernel.address() as { port: number }).port;

  const { app } = createServer({
    port: 0, token: 'tok', haskellHost: '127.0.0.1', haskellPort: kernelPort,
  });
  await new Promise<void>(resolve => { sched = app.listen(0, '127.0.0.1', () => resolve()); });
  base = `http://127.0.0.1:${(sched.address() as { port: number }).port}`;
});

afterEach(async () => {
  await new Promise<void>(resolve => sched?.close(() => resolve()) ?? resolve());
  await new Promise<void>(resolve => kernel?.close(() => resolve()) ?? resolve());
});

const H = { Authorization: 'Bearer tok', 'Content-Type': 'application/json' };

describe('P3 — kernel constraint reaches the UI', () => {
  it('forwards trha_constraint verbatim on /api/agent/step', async () => {
    const start = await fetch(`${base}/api/session/start`, {
      method: 'POST', headers: H, body: JSON.stringify({ mode: 'standard' }),
    });
    expect(start.status).toBe(200);
    const { sessionId } = await start.json() as { sessionId: string };

    const step = await fetch(`${base}/api/agent/step`, {
      method: 'POST', headers: H,
      body: JSON.stringify({ sessionId, message: 'hi' }),
    });
    expect(step.status).toBe(200);
    const body = await step.json() as Record<string, unknown>;

    // 既有字段未被破坏
    expect(body.reply).toBe('ok');
    expect(body.mode).toBe('standard');
    expect(Array.isArray(body.messages)).toBe(true);

    // ★ 新增：约束判定透传（P3）
    expect(body.constraint).toBeDefined();
    const c = body.constraint as Record<string, unknown>;
    expect(c.status).toBe('warn');
    expect(c.reach).toBe(true);
    expect(c.edges).toBe(2);
    expect(c.reason).toBe('berry phase drift');
    // 判定分量齐全：t6 三分量
    const t6 = c.t6 as Record<string, unknown>;
    expect(t6).toMatchObject({ polar: 3, toroidal: 7, berry: 11 });
    // 判定状态只有 pass / warn（类型里没有「拒绝」）
    expect(['pass', 'warn']).toContain(c.status);
  });

  it('omits constraint when the kernel does not attach one (no fabricated field)', async () => {
    kernelBody = { choices: [{ message: { content: 'plain' } }] };
    const start = await fetch(`${base}/api/session/start`, {
      method: 'POST', headers: H, body: JSON.stringify({ mode: 'standard' }),
    });
    const { sessionId } = await start.json() as { sessionId: string };
    const step = await fetch(`${base}/api/agent/step`, {
      method: 'POST', headers: H, body: JSON.stringify({ sessionId, message: 'hi' }),
    });
    const body = await step.json() as Record<string, unknown>;
    expect(body.reply).toBe('plain');
    // 内核没给就不该凭空造一个
    expect('constraint' in body).toBe(false);
  });
});
