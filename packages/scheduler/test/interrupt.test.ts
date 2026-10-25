// Interrupt endpoint (M3.5-3): the CLI's double-escape posts here.
//
// Two behaviours matter:
//   - an idle session is refused (`aborted: false`) and left untouched —
//     setting the flag there would abort the *next* turn;
//   - a busy session gets the flag, and the flag is cleared when the turn
//     ends so a late interrupt cannot leak into the following turn.

import express from 'express';
import { describe, it, expect } from 'vitest';
import type { Server } from 'http';
import type { AddressInfo } from 'net';
import { createServer } from '../src/Server/index.js';

async function listen(app: express.Express): Promise<{ port: number; server: Server }> {
  const server = await new Promise<Server>((resolve) => {
    const s = app.listen(0, '127.0.0.1', () => resolve(s));
  });
  const { port } = server.address() as AddressInfo;
  return { port, server };
}

const auth = { 'Content-Type': 'application/json', Authorization: 'Bearer dev-token' } as Record<string, string>;
const sleep = (ms: number) => new Promise(r => setTimeout(r, ms));

/** Minimal kernel: session start plus a chat reply, optionally delayed. */
function fakeKernel(delayMs = 0) {
  const kernel = express();
  kernel.use(express.json());
  kernel.post('/session/start', (_req, res) => { res.json({ sessionId: 'x', resumed: false }); });
  kernel.post('/v1/chat/completions', (_req, res) => {
    const reply = () => res.json({
      choices: [{ message: { role: 'assistant', content: 'done' }, finish_reason: 'stop' }],
    });
    if (delayMs > 0) setTimeout(reply, delayMs);
    else reply();
  });
  return kernel;
}

async function setup(delayMs = 0) {
  const kernelServer = await listen(fakeKernel(delayMs));
  const { app } = createServer({
    port: 0, token: 'dev-token',
    haskellHost: '127.0.0.1', haskellPort: kernelServer.port,
  });
  const schedulerServer = await listen(app);
  const base = `http://127.0.0.1:${schedulerServer.port}`;
  const start = await fetch(`${base}/api/session/start`, {
    method: 'POST', headers: auth, body: JSON.stringify({ mode: 'standard' }),
  });
  const { sessionId } = (await start.json()) as { sessionId: string };
  const close = () => { kernelServer.server.close(); schedulerServer.server.close(); };
  return { base, sessionId, close };
}

async function interrupt(base: string, sessionId: string): Promise<boolean> {
  const res = await fetch(`${base}/api/session/${sessionId}/interrupt`, {
    method: 'POST', headers: auth, body: '{}',
  });
  const body = (await res.json()) as { aborted?: boolean };
  return body.aborted === true;
}

async function step(base: string, sessionId: string): Promise<string> {
  const res = await fetch(`${base}/api/agent/step`, {
    method: 'POST', headers: auth,
    body: JSON.stringify({ sessionId, message: 'hi' }),
  });
  const body = (await res.json()) as { reply?: string };
  return body.reply ?? '';
}

describe('interrupt endpoint', () => {
  it('refuses an idle session without poisoning the next turn', async () => {
    const { base, sessionId, close } = await setup();
    try {
      expect(await interrupt(base, sessionId)).toBe(false);
      expect(await step(base, sessionId)).toBe('done');
    } finally {
      close();
    }
  });

  it('aborts a busy session and clears the flag when the turn ends', async () => {
    const { base, sessionId, close } = await setup(300);
    try {
      const inFlight = step(base, sessionId);
      let aborted = false;
      for (let i = 0; i < 50 && !aborted; i++) {
        aborted = await interrupt(base, sessionId);
        if (!aborted) await sleep(20);
      }
      expect(aborted).toBe(true);
      expect(await inFlight).toBe('done');
      // The turn ended without observing the flag; the finally block must
      // have cleared it, so the next turn runs normally.
      expect(await step(base, sessionId)).toBe('done');
    } finally {
      close();
    }
  });
});
