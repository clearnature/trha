// Side-channel events on /api/events: reasoning deltas (agent:reasoning) and
// step boundaries (agent:model-request) must reach the shell, or the TUI
// cannot render a thinking card or a round separator.

import { describe, it, expect } from 'vitest';
import express from 'express';
import { createServer } from '../src/Server/index.js';
import type { Server } from 'http';
import type { AddressInfo } from 'net';

const auth = { 'Content-Type': 'application/json', Authorization: 'Bearer dev-token' } as Record<string, string>;

async function listen(app: express.Express): Promise<{ port: number; server: Server }> {
  const s = await new Promise<Server>(resolve => {
    const srv = app.listen(0, '127.0.0.1', () => resolve(srv));
  });
  return { port: (s.address() as AddressInfo).port, server: s };
}

/** Kernel stub: answers /session/start and streams reasoning + text + usage. */
function streamingKernel(): express.Express {
  const kernel = express();
  kernel.use(express.json());
  kernel.post('/session/start', (_req, res) => res.json({ sessionId: 'k1', resumed: false }));
  kernel.post('/v1/chat/completions/stream', (_req, res) => {
    res.writeHead(200, { 'Content-Type': 'text/event-stream' });
    res.write(`data: ${JSON.stringify({ choices: [{ delta: { reasoning_content: 'think' } }] })}\n\n`);
    res.write(`data: ${JSON.stringify({ choices: [{ delta: { reasoning_content: 'ing' } }] })}\n\n`);
    res.write(`data: ${JSON.stringify({ choices: [{ delta: { content: 'answer' } }] })}\n\n`);
    res.write(`data: ${JSON.stringify({ usage: { prompt_tokens: 5, completion_tokens: 2, total_tokens: 7 } })}\n\n`);
    res.write('data: [DONE]\n\n');
    res.end();
  });
  return kernel;
}

interface Frame { reasoning?: string; round?: number; messageCount?: number; toolCount?: number; text?: string }

async function readSse(base: string, sessionId: string, timeoutMs: number): Promise<Frame[]> {
  const res = await fetch(`${base}/api/events/${sessionId}`, { headers: auth });
  const reader = res.body!.getReader();
  const decoder = new TextDecoder();
  let buf = '';
  const frames: Frame[] = [];
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
        if (line.startsWith('data: ')) frames.push(JSON.parse(line.slice(6)) as Frame);
      }
      if (frames.some(f => f.text === 'answer')) {
        await new Promise(r => setTimeout(r, 50));
        return frames;
      }
    }
  }
  return frames;
}

describe('side-channel agent events', () => {
  it('forwards reasoning deltas and the step boundary', async () => {
    const kernelServer = await listen(streamingKernel());
    const { app } = createServer({
      port: 0, token: 'dev-token', haskellHost: '127.0.0.1', haskellPort: kernelServer.port,
    });
    const schedulerServer = await listen(app);
    const base = `http://127.0.0.1:${schedulerServer.port}`;

    const start = await fetch(`${base}/api/session/start`, { method: 'POST', headers: auth, body: JSON.stringify({ mode: 'standard' }) });
    const { sessionId } = (await start.json()) as { sessionId: string };

    const stream = readSse(base, sessionId, 3000);
    await new Promise(r => setTimeout(r, 100));
    await fetch(`${base}/api/agent/step`, {
      method: 'POST', headers: auth, body: JSON.stringify({ sessionId, message: 'go' }),
    });

    const frames = await stream;
    expect(frames.filter(f => f.reasoning).map(f => f.reasoning)).toEqual(['think', 'ing']);
    const step = frames.find(f => f.round !== undefined);
    expect(step).toBeDefined();
    expect(step?.messageCount).toBeGreaterThanOrEqual(0);
    expect(step?.toolCount).toBeGreaterThanOrEqual(0);

    kernelServer.server.close();
    schedulerServer.server.close();
  });
});
