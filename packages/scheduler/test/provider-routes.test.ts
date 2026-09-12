// P4: /api/providers* forwarding from the scheduler to the kernel.
//
// The kernel owns the registry; the scheduler is the UI's only door, so these
// routes must forward the body, the status and the coded refusals -- and say
// something actionable when the kernel is not there.

import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import type { Server } from 'node:http';
import { createServer as createHttpServer } from 'node:http';
import { createServer } from '../src/Server/index.js';

let sched: Server;
let kernel: Server;
let base = '';
const seen: { method?: string; url?: string; body?: string }[] = [];
let kernelStatus = 200;
let kernelBody: unknown = { providers: [] };

beforeEach(async () => {
  seen.length = 0;
  kernelStatus = 200;
  kernelBody = { providers: [] };

  kernel = createHttpServer((req, res) => {
    let body = '';
    req.on('data', c => { body += c; });
    req.on('end', () => {
      seen.push({ method: req.method, url: req.url, body });
      res.writeHead(kernelStatus, { 'Content-Type': 'application/json' });
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

describe('provider routes (P4 forwarding)', () => {
  it('forwards GET /api/providers to the kernel', async () => {
    kernelBody = { providers: [{ name: 'k' }] };
    const r = await fetch(`${base}/api/providers`, { headers: H });
    expect(r.status).toBe(200);
    expect(await r.json()).toEqual({ providers: [{ name: 'k' }] });
    expect(seen.at(-1)).toMatchObject({ method: 'GET', url: '/providers' });
  });

  it('forwards GET /api/providers/protocols', async () => {
    kernelBody = [{ kind: 'openai' }];
    const r = await fetch(`${base}/api/providers/protocols`, { headers: H });
    expect(r.status).toBe(200);
    expect(await r.json()).toEqual([{ kind: 'openai' }]);
    expect(seen.at(-1)).toMatchObject({ method: 'GET', url: '/providers/protocols' });
  });

  it('forwards the body on POST and returns the kernel answer', async () => {
    kernelBody = { kind: 'openai', models: ['a'] };
    const r = await fetch(`${base}/api/providers/probe`, {
      method: 'POST', headers: H,
      body: JSON.stringify({ baseUrl: 'http://x', apiKey: 'k' }),
    });
    expect(r.status).toBe(200);
    expect(await r.json()).toMatchObject({ kind: 'openai' });
    expect(JSON.parse(seen.at(-1)?.body ?? '{}')).toEqual({ baseUrl: 'http://x', apiKey: 'k' });
  });

  it('passes the kernel status and coded refusal through', async () => {
    kernelStatus = 404;
    kernelBody = { code: 'provider.path_missing', error: 'nope' };
    const r = await fetch(`${base}/api/providers/probe`, {
      method: 'POST', headers: H, body: '{}',
    });
    expect(r.status).toBe(404);
    expect((await r.json() as { code: string }).code).toBe('provider.path_missing');
  });

  it('reports an unreachable kernel as a coded 502, not a hang', async () => {
    await new Promise<void>(resolve => kernel.close(() => resolve()));
    const r = await fetch(`${base}/api/providers`, { headers: H });
    expect(r.status).toBe(502);
    expect((await r.json() as { code: string }).code).toBe('provider.kernel_unreachable');
  });

  it('keeps the existing door: loopback reads need no token, writes do', async () => {
    const read = await fetch(`${base}/api/providers`);
    expect(read.status).toBe(200);
    const write = await fetch(`${base}/api/providers/remove`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}',
    });
    expect(write.status).toBe(401);
  });

  it('forwards the edit / websearch / thinking routes (P8)', async () => {
    const cases: [{ name: string } & Record<string, unknown>, string][] = [
      [{ name: 'gw', default: 'm-b' }, '/providers/edit'],
      [{ name: 'gw', on: true }, '/providers/websearch'],
      [{ name: 'gw', on: false }, '/providers/thinking'],
    ];
    for (const [body, path] of cases) {
      await fetch(`${base}/api${path}`, { method: 'POST', headers: H, body: JSON.stringify(body) });
      expect(seen.at(-1)).toMatchObject({ method: 'POST', url: path });
      expect(JSON.parse(seen.at(-1)?.body ?? '{}')).toEqual(body);
    }
  });

  it('carries the chosen provider/model into the kernel call (P6)', async () => {
    kernelBody = {
      choices: [{ index: 0, message: { role: 'assistant', content: 'ok' } }],
      usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 },
    };
    const started = await fetch(`${base}/api/session/start`, {
      method: 'POST', headers: H, body: JSON.stringify({ mode: 'minimal' }),
    }).then(r => r.json()) as { sessionId: string };
    expect(started.sessionId).toBeTruthy();

    await fetch(`${base}/api/agent/step`, {
      method: 'POST', headers: H,
      body: JSON.stringify({ sessionId: started.sessionId, message: 'hi', provider: 'gw', model: 'm-b' }),
    });

    const chat = seen.filter(s => s.url === '/v1/chat/completions').at(-1);
    expect(chat, 'a kernel chat call happened').toBeTruthy();
    expect(JSON.parse(chat?.body ?? '{}')).toMatchObject({ provider: 'gw', model: 'm-b' });
  });
});
