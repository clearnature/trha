import { describe, expect, it } from 'vitest';
import type { Server } from 'node:http';
import { createServer as httpCreate } from 'node:http';
import { SchedulerPort } from '../src/renderer/port/http.js';
import type { PortEvent } from '../src/renderer/port/types.js';

// Stub scheduler with the real route shapes (subset needed by the port).
let srv: Server;
let base = '';
let token = '';

const json = (res: { writeHead: (n: number, h: Record<string, string>) => void; end: (s: string) => void }, n: number, body: unknown) => {
  res.writeHead(n, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(body));
};

beforeEach(async () => {
  token = 'test-token';
  srv = httpCreate((req, res) => {
    const url = new URL(req.url ?? '/', 'http://x');
    const authOk = req.headers.authorization === `Bearer ${token}` || url.pathname.startsWith('/studio');
    if (!authOk) { json(res, 401, { error: 'Unauthorized' }); return; }
    if (req.method === 'GET' && url.pathname === '/api/modes') return json(res, 200, { standard: { name: 'standard', description: 'd', tools: [] } });
    if (req.method === 'GET' && url.pathname === '/api/models') return json(res, 200, [{ name: 'm', description: 'd', contextSize: 1 }]);
    if (req.method === 'GET' && url.pathname === '/api/sessions') return json(res, 200, [{ id: 's1', mode: 'standard', messages: [], pendingApproval: null, createdAt: 't' }]);
    if (req.method === 'POST' && url.pathname === '/api/session/start') return json(res, 200, { sessionId: 's2', mode: 'standard' });
    if (req.method === 'DELETE' && url.pathname === '/api/session/s1') return json(res, 200, { ok: true });
    if (req.method === 'POST' && url.pathname === '/api/agent/step') return json(res, 200, { reply: 'hi', messages: [], mode: 'standard' });
    if (req.method === 'POST' && url.pathname === '/api/session/s1/decision') return json(res, 200, { status: 'approved', reply: 'ok', messages: [], mode: 'standard' });
    if (req.method === 'GET' && url.pathname === '/api/session/s1/messages') return json(res, 200, { messages: [] });
    if (req.method === 'GET' && url.pathname === '/studio/versions') return json(res, 200, { current: '0.1.0', pinned: null, versions: [] });
    if (req.method === 'GET' && url.pathname === '/api/events/s1') {
      res.writeHead(200, { 'Content-Type': 'text/event-stream' });
      res.write('data: {"role":"user","content":"hello"}\n\n');
      res.write('data: {"role":"assistant","content":"world"}\n\n');
      res.end();
      return;
    }
    json(res, 404, { error: 'no' });
  });
  await new Promise<void>(resolve => srv.listen(0, '127.0.0.1', () => resolve()));
  const addr = srv.address();
  if (addr && typeof addr === 'object') base = `http://127.0.0.1:${addr.port}`;
});
afterEach(async () => {
  await new Promise<void>(resolve => srv?.close(() => resolve()));
});

const port = () => new SchedulerPort({ base, useToken: true }, token);

describe('SchedulerPort http', () => {
  it('reads modes/models/sessions', async () => {
    const p = port();
    expect(Object.keys(await p.modes())).toContain('standard');
    expect((await p.models())[0].name).toBe('m');
    expect((await p.listSessions())[0].id).toBe('s1');
  });

  it('creates and deletes sessions', async () => {
    const p = port();
    expect((await p.createSession('standard')).sessionId).toBe('s2');
    await expect(p.deleteSession('s1')).resolves.toBeUndefined();
  });

  it('runs a step and a decision', async () => {
    const p = port();
    const out = await p.step('s1', 'hello');
    if (out.status === 'awaiting_approval') throw new Error('unexpected');
    expect(out.reply).toBe('hi');
    const d = await p.decision('s1', true);
    if (d.status !== 'approved') throw new Error('unexpected');
    expect(d.reply).toBe('ok');
  });

  it('reads session messages and studio version', async () => {
    const p = port();
    expect(await p.sessionMessages('s1')).toEqual([]);
    expect((await p.studioVersion()).current).toBe('0.1.0');
  });

  it('401 surfaces as an HTTP error', async () => {
    const p = new SchedulerPort({ base, useToken: true }, 'wrong');
    await expect(p.listSessions()).rejects.toThrow(/401/);
  });

  it('subscribe consumes the SSE stream into PortEvents', async () => {
    const seen: PortEvent[] = [];
    await new Promise<void>(resolve => {
      const off = port().subscribe('s1', e => {
        seen.push(e);
        if (seen.length === 2) { off(); resolve(); }
      });
    });
    expect(seen.map(e => (e.type === 'message' ? e.content : ''))).toEqual(['hello', 'world']);
  });
});
