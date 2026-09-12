// Phase 2 S2: tool lifecycle events over SSE (demo injection in the
// fallback path of /api/agent/step).

import { describe, it, expect } from 'vitest';
import { createServer } from '../src/Server/index.js';
import type { Server } from 'http';
import type { AddressInfo } from 'net';
import type { Express } from 'express';

type ToolUpdate = {
  sessionId: string;
  name: string;
  status: 'running' | 'succeeded' | 'failed';
  durationMs?: number;
};

async function listen(app: Express): Promise<{ base: string; server: Server }> {
  const server = await new Promise<Server>((resolve) => {
    const s = app.listen(0, '127.0.0.1', () => resolve(s));
  });
  const { port } = server.address() as AddressInfo;
  return { base: `http://127.0.0.1:${port}`, server };
}

async function readSse(base: string, sessionId: string, timeoutMs: number): Promise<ToolUpdate[]> {
  const res = await fetch(`${base}/api/events/${sessionId}`, {
    headers: { Authorization: 'Bearer dev-token' },
  });
  const reader = res.body!.getReader();
  const decoder = new TextDecoder();
  let buf = '';
  const events: ToolUpdate[] = [];
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const { value, done } = await reader.read();
    if (done) break;
    buf += decoder.decode(value, { stream: true });
    let idx: number;
    while ((idx = buf.indexOf('\n\n')) >= 0) {
      const frame = buf.slice(0, idx);
      buf = buf.slice(idx + 2);
      for (const line of frame.split('\n')) {
        if (line.startsWith('data: ')) {
          const parsed = JSON.parse(line.slice(6)) as ToolUpdate;
          if (parsed.name === 'bash') events.push(parsed);
        }
      }
      // a completed tool lifecycle is enough
      if (events.some(e => e.status === 'succeeded')) return events;
    }
  }
  return events;
}

describe('tool events (Phase 2 S2)', () => {
  it('emits a running -> succeeded lifecycle on the fallback path', async () => {
    const { app } = createServer({ port: 0, token: 'dev-token' });
    const { base, server } = await listen(app);

    const sid = `session-tool-${Date.now()}`;
    // seed session like the server would (session store is inside createServer,
    // so create via the API instead)
    const start = await fetch(`${base}/api/session/start`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: 'Bearer dev-token' },
      body: JSON.stringify({ mode: 'standard' }),
    });
    const { sessionId } = (await start.json()) as { sessionId: string };

    const stream = readSse(base, sessionId, 2000);
    // give the SSE subscription a moment to attach
    await new Promise(r => setTimeout(r, 100));

    await fetch(`${base}/api/agent/step`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: 'Bearer dev-token' },
      body: JSON.stringify({ sessionId, message: 'run something' }),
    });

    const events = await stream;
    expect(events.map(e => e.status)).toEqual(['running', 'succeeded']);
    expect(events[0].name).toBe('bash');
    expect(events[1].durationMs).toBeGreaterThanOrEqual(0);
    expect(events[0].sessionId).toBe(sessionId);

    server.close();
  });
});
