// Two steps on one session must not interleave.
//
// Before the lock, both callers ran `runStep` at once and pushed into the same
// `messages` array: user, user, assistant, assistant — a transcript that either
// confuses the model or gets rejected outright. The lock queues the second turn.

import express from 'express';
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import type { Server } from 'http';
import type { AddressInfo } from 'net';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { createServer } from '../src/Server/index.js';
import { isSessionBusy, resetSessionLocks, withSessionLock } from '../src/Server/sessionLock.js';

const auth = { 'Content-Type': 'application/json', Authorization: 'Bearer dev-token' } as Record<string, string>;

async function listen(app: express.Express): Promise<{ port: number; server: Server }> {
  const s = await new Promise<Server>(resolve => {
    const srv = app.listen(0, '127.0.0.1', () => resolve(srv));
  });
  return { port: (s.address() as AddressInfo).port, server: s };
}

const wait = (ms: number): Promise<void> => new Promise(r => setTimeout(r, ms));

/** Answers after a delay so two requests genuinely overlap. */
function slowKernel(delayMs: number) {
  const kernel = express();
  kernel.use(express.json());
  kernel.post('/session/start', (_q, res) => res.json({}));
  kernel.post('/v1/chat/completions', async (req, res) => {
    const msgs = req.body.messages as Array<{ role: string; content: string }>;
    const lastUser = [...msgs].reverse().find(m => m.role === 'user')?.content ?? '';
    await wait(delayMs);
    res.json({ choices: [{ message: { role: 'assistant', content: `answer:${lastUser}`, finish_reason: 'stop' } }] });
  });
  return kernel;
}

describe('session lock', () => {
  it('runs callers one at a time, in order', async () => {
    resetSessionLocks();
    const order: string[] = [];
    let concurrent = 0;
    let maxConcurrent = 0;
    const job = (tag: string, ms: number) => withSessionLock('s1', async () => {
      concurrent += 1;
      maxConcurrent = Math.max(maxConcurrent, concurrent);
      order.push(`start:${tag}`);
      await wait(ms);
      order.push(`end:${tag}`);
      concurrent -= 1;
      return tag;
    });
    const results = await Promise.all([job('a', 60), job('b', 5), job('c', 1)]);
    expect(results).toEqual(['a', 'b', 'c']);
    expect(maxConcurrent).toBe(1);
    expect(order).toEqual(['start:a', 'end:a', 'start:b', 'end:b', 'start:c', 'end:c']);
    // the queue drains, so the session is not left marked busy
    expect(isSessionBusy('s1')).toBe(false);
  });

  it('does not wedge after a failed turn', async () => {
    resetSessionLocks();
    await expect(withSessionLock('s2', async () => { throw new Error('boom'); })).rejects.toThrow('boom');
    await expect(withSessionLock('s2', async () => 'ok')).resolves.toBe('ok');
  });

  it('keeps different sessions independent', async () => {
    resetSessionLocks();
    let concurrent = 0;
    let maxConcurrent = 0;
    const job = (id: string) => withSessionLock(id, async () => {
      concurrent += 1;
      maxConcurrent = Math.max(maxConcurrent, concurrent);
      await wait(30);
      concurrent -= 1;
    });
    await Promise.all([job('x'), job('y')]);
    expect(maxConcurrent).toBe(2);   // parallel across sessions is fine
  });
});

describe('concurrent HTTP steps on one session', () => {
  let dir: string;
  beforeEach(async () => {
    dir = await mkdtemp(path.join(tmpdir(), 'trha-lock-'));
    process.env.TRHA_WORKSPACE = dir;
    process.env.TRHA_SCHEDULE_TICK_MS = '0';
    resetSessionLocks();
  });
  afterEach(async () => {
    delete process.env.TRHA_WORKSPACE;
    delete process.env.TRHA_SCHEDULE_TICK_MS;
    await rm(dir, { recursive: true, force: true });
  });

  it('serializes two overlapping requests instead of interleaving them', async () => {
    const kernel = slowKernel(120);
    const kernelServer = await listen(kernel);
    const stateDir = path.join(dir, 'state');
    const { app, stop } = createServer({
      port: 0, token: 'dev-token', haskellHost: '127.0.0.1', haskellPort: kernelServer.port, stateDir,
    });
    const schedulerServer = await listen(app);
    const base = `http://127.0.0.1:${schedulerServer.port}`;

    const start = await fetch(`${base}/api/session/start`, {
      method: 'POST', headers: auth, body: JSON.stringify({ mode: 'standard' }),
    });
    const { sessionId } = (await start.json()) as { sessionId: string };

    const step = (message: string) => fetch(`${base}/api/agent/step`, {
      method: 'POST', headers: auth, body: JSON.stringify({ sessionId, message }),
    });
    const [r1, r2] = await Promise.all([step('first'), step('second')]);
    expect(r1.status).toBe(200);
    expect(r2.status).toBe(200);
    // the write is fire-and-forget on the response path; let it land
    await wait(200);

    const record = JSON.parse(
      await readFile(path.join(stateDir, `${sessionId}.json`), 'utf8'),
    ) as { messages: Array<{ role: string; content: string }> };

    // exactly: user, assistant, user, assistant — never user, user, ...
    expect(record.messages.map(m => m.role)).toEqual(['user', 'assistant', 'user', 'assistant']);
    expect(record.messages[0]!.content).toBe('first');
    expect(record.messages[1]!.content).toBe('answer:first');
    expect(record.messages[2]!.content).toBe('second');
    expect(record.messages[3]!.content).toBe('answer:second');

    stop(); kernelServer.server.close(); schedulerServer.server.close();
  });
});
