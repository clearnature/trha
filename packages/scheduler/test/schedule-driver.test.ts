// Schedule driver: a schedule record is only half the feature — something must
// turn `at` into a turn. These tests pin the firing rules:
//
//   * one-shot fires once and becomes `fired`
//   * repeating fires again after `repeat_ms`, and stops when cancelled
//   * a schedule that came due long before boot is `missed`, not replayed
//   * nothing fires while a decision is pending
//
// The state file is the assertion surface: it is what a restarted process
// actually reads.

import express from 'express';
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import type { Server } from 'http';
import type { AddressInfo } from 'net';
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
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

/** Kernel that always answers; counts how many turns it served. */
function countingKernel() {
  const kernel = express();
  kernel.use(express.json());
  const state = { calls: 0 };
  kernel.post('/session/start', (_req, res) => res.json({ sessionId: 'x', resumed: false }));
  kernel.post('/v1/chat/completions', (_req, res) => {
    state.calls += 1;
    res.json({ choices: [{ message: { role: 'assistant', content: `answer ${state.calls}`, finish_reason: 'stop' } }] });
  });
  return { kernel, state };
}

interface Booted { base: string; kernelCalls: () => number; close: () => void }

async function boot(dir: string, stateDir: string): Promise<Booted> {
  const { kernel, state } = countingKernel();
  const kernelServer = await listen(kernel);
  const { app, stop } = createServer({
    port: 0, token: 'dev-token', haskellHost: '127.0.0.1', haskellPort: kernelServer.port, stateDir,
  });
  const schedulerServer = await listen(app);
  return {
    base: `http://127.0.0.1:${schedulerServer.port}`,
    kernelCalls: () => state.calls,
    // stop() first: a closed listener with a live timer keeps spending
    close: () => { stop(); kernelServer.server.close(); schedulerServer.server.close(); },
  };
}

const readRecord = async (stateDir: string, sessionId: string): Promise<Record<string, unknown>> =>
  JSON.parse(await readFile(path.join(stateDir, `${sessionId}.json`), 'utf8')) as Record<string, unknown>;

const wait = (ms: number): Promise<void> => new Promise(r => setTimeout(r, ms));

const scheduleOf = (rec: Record<string, unknown>): Record<string, unknown> =>
  (rec.schedules as Array<Record<string, unknown>>)[0] ?? {};

/** Seed a session file with one schedule; the driver reads exactly this. */
async function seed(
  stateDir: string, sessionId: string,
  schedule: Record<string, unknown>,
  extra: Record<string, unknown> = {},
): Promise<void> {
  await mkdir(stateDir, { recursive: true });
  const now = new Date().toISOString();
  const record = {
    v: 2, sessionId, mode: 'standard', messages: [], pendingApproval: null,
    createdAt: now, updatedAt: now, schedules: [schedule], ...extra,
  };
  await writeFile(path.join(stateDir, `${sessionId}.json`), JSON.stringify(record), 'utf8');
}

describe('schedule driver', () => {
  let dir: string;
  beforeEach(async () => {
    dir = await mkdtemp(path.join(tmpdir(), 'trha-sched-'));
    process.env.TRHA_WORKSPACE = dir;
    process.env.TRHA_SCHEDULE_TICK_MS = '25';
    process.env.TRHA_SCHEDULE_GRACE_MS = '10000';
  });
  afterEach(async () => {
    delete process.env.TRHA_WORKSPACE;
    delete process.env.TRHA_SCHEDULE_TICK_MS;
    delete process.env.TRHA_SCHEDULE_GRACE_MS;
    await rm(dir, { recursive: true, force: true });
  });

  it('fires a one-shot schedule as a real turn and records it as fired', async () => {
    const stateDir = path.join(dir, 'state1');
    const sessionId = 'once-1';
    await seed(stateDir, sessionId, {
      id: 'sch-1', prompt: 'check the build',
      at: new Date(Date.now() + 30).toISOString(), status: 'active', runs: 0,
    });

    const app = await boot(dir, stateDir);
    await wait(400);
    const after = await readRecord(stateDir, sessionId);

    const sched = scheduleOf(after);
    expect(sched.status).toBe('fired');
    expect(sched.runs).toBe(1);
    expect(sched.lastFiredAt).toBeTruthy();

    // the prompt went through the normal turn path, and the reply was stored
    const msgs = after.messages as Array<{ role: string; content: string }>;
    expect(msgs.some(m => m.role === 'user' && m.content === 'check the build')).toBe(true);
    expect(msgs.some(m => m.role === 'assistant' && m.content.startsWith('answer'))).toBe(true);
    expect(app.kernelCalls()).toBeGreaterThanOrEqual(1);
    app.close();
  });

  it('repeats on repeat_ms, and a cancelled schedule stops firing', async () => {
    const stateDir = path.join(dir, 'state2');
    const sessionId = 'repeat-1';
    await seed(stateDir, sessionId, {
      id: 'sch-1', prompt: 'tick',
      at: new Date(Date.now() + 20).toISOString(), repeatMs: 80, status: 'active', runs: 0,
    });

    const app = await boot(dir, stateDir);
    await wait(450);
    app.close();
    const mid = await readRecord(stateDir, sessionId);
    const sched = scheduleOf(mid);
    expect(Number(sched.runs)).toBeGreaterThanOrEqual(2);
    expect(sched.status).toBe('active');              // still repeating

    // cancel on disk, reboot: the timer must not keep spending
    const runsAtCancel = Number(sched.runs);
    await seed(stateDir, sessionId, { ...sched, status: 'cancelled' }, { messages: mid.messages });
    const app2 = await boot(dir, stateDir);
    await wait(300);
    app2.close();
    const after = await readRecord(stateDir, sessionId);
    expect(Number(scheduleOf(after).runs)).toBe(runsAtCancel);
  });

  it('marks a long-overdue one-shot as missed instead of replaying it', async () => {
    const stateDir = path.join(dir, 'state3');
    const sessionId = 'overdue-1';
    await seed(stateDir, sessionId, {
      id: 'sch-1', prompt: 'too late',
      at: new Date(Date.now() - 3600_000).toISOString(), status: 'active', runs: 0,
    });

    const app = await boot(dir, stateDir);
    await wait(150);
    const after = await readRecord(stateDir, sessionId);
    expect(scheduleOf(after).status).toBe('missed');
    expect(app.kernelCalls()).toBe(0);
    app.close();
  });

  it('does not fire while a decision is pending', async () => {
    const stateDir = path.join(dir, 'state4');
    const sessionId = 'gated-1';
    await seed(stateDir, sessionId, {
      id: 'sch-1', prompt: 'blocked',
      at: new Date(Date.now() + 10).toISOString(), status: 'active', runs: 0,
    }, { pendingApproval: { message: 'approve me' } });

    const app = await boot(dir, stateDir);
    await wait(250);
    const after = await readRecord(stateDir, sessionId);
    expect(scheduleOf(after).status).toBe('active');
    expect(app.kernelCalls()).toBe(0);
    app.close();
  });

  it('creates a schedule through the tool and the driver picks it up', async () => {
    // End-to-end through the model-facing tool, not a hand-written file.
    const stateDir = path.join(dir, 'state5');
    const sessionId = 'tool-1';
    await seed(stateDir, sessionId, {
      id: 'seed', prompt: 'seed', at: new Date(Date.now() + 3600_000).toISOString(),
      status: 'cancelled', runs: 0,
    });

    const kernel = express();
    kernel.use(express.json());
    let round = 0;
    kernel.post('/session/start', (_req, res) => res.json({ sessionId: 'x', resumed: false }));
    kernel.post('/v1/chat/completions', (req, res) => {
      const msgs = req.body.messages as Array<{ role: string; content: string }>;
      if (round++ === 0) {
        const at = new Date(Date.now() + 40).toISOString();
        const args = JSON.stringify({ prompt: 'from the tool', at });
        return res.json({ choices: [{ message: { role: 'assistant', content: '', tool_calls: [{ id: 'c1', type: 'function', function: { name: 'schedule_create', arguments: args } }] }, finish_reason: 'tool_calls' }] });
      }
      res.json({ choices: [{ message: { role: 'assistant', content: `ok: ${msgs.filter(m => m.role === 'tool').length} tools`, finish_reason: 'stop' } }] });
    });
    const kernelServer = await listen(kernel);
    const { app, stop } = createServer({
      port: 0, token: 'dev-token', haskellHost: '127.0.0.1', haskellPort: kernelServer.port, stateDir,
    });
    const schedulerServer = await listen(app);
    const base = `http://127.0.0.1:${schedulerServer.port}`;

    await fetch(`${base}/api/agent/step`, {
      method: 'POST', headers: auth,
      body: JSON.stringify({ sessionId, message: 'schedule something' }),
    });
    await wait(400);

    const after = await readRecord(stateDir, sessionId);
    const list = after.schedules as Array<Record<string, unknown>>;
    const created = list.find(s => s.prompt === 'from the tool');
    expect(created).toBeTruthy();
    expect(created?.status).toBe('fired');
    expect(created?.runs).toBe(1);

    stop();
    kernelServer.server.close();
    schedulerServer.server.close();
  });
});
