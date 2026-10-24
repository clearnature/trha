// Schedules across days and time zones.
//
// `at` arrives as whatever the model wrote — often an ISO string with an offset
// ("2030-01-01T09:00:00+08:00"). It must be stored as the UTC instant it names,
// not reinterpreted in local time, or a schedule fires eight hours off. And a
// repeating schedule whose slot passed while the process was down has to fire
// now and move its cursor forward, instead of firing immediately forever.

import express from 'express';
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import type { Server } from 'http';
import type { AddressInfo } from 'net';
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { createServer } from '../src/Server/index.js';
import { runStandardTool, type StandardToolHost } from '../src/Server/standardTools.js';

async function listen(app: express.Express): Promise<{ port: number; server: Server }> {
  const s = await new Promise<Server>(resolve => {
    const srv = app.listen(0, '127.0.0.1', () => resolve(srv));
  });
  return { port: (s.address() as AddressInfo).port, server: s };
}

function kernel() {
  const k = express();
  k.use(express.json());
  k.post('/session/start', (_q, res) => res.json({}));
  k.post('/v1/chat/completions', (_q, res) => {
    res.json({ choices: [{ message: { role: 'assistant', content: 'ok', finish_reason: 'stop' } }] });
  });
  return k;
}

const wait = (ms: number): Promise<void> => new Promise(r => setTimeout(r, ms));
const readRecord = async (dir: string, sid: string): Promise<Record<string, unknown>> =>
  JSON.parse(await readFile(path.join(dir, `${sid}.json`), 'utf8')) as Record<string, unknown>;
const scheduleOf = (rec: Record<string, unknown>): Record<string, unknown> =>
  (rec.schedules as Array<Record<string, unknown>>)[0] ?? {};

describe('schedule time handling', () => {
  let dir: string;
  beforeEach(async () => {
    dir = await mkdtemp(path.join(tmpdir(), 'trha-time-'));
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

  it('stores an offset timestamp as the instant it names', async () => {
    let tasks: Array<{ id: string }> = [];
    void tasks;
    const host: StandardToolHost = { workspace: dir, state: {}, jobs: new Map(), sessionId: 's' };
    await runStandardTool('schedule_create', {
      prompt: 'new year',
      at: '2030-01-01T09:00:00+08:00',
    }, host);
    const stored = host.state.schedules?.[0];
    // 09:00 in +08:00 is 01:00 UTC — not 09:00 local
    expect(stored?.at).toBe('2030-01-01T01:00:00.000Z');
  });

  async function boot(stateDir: string) {
    const k = kernel();
    const kernelServer = await listen(k);
    const { app, stop } = createServer({
      port: 0, token: 'dev-token', haskellHost: '127.0.0.1', haskellPort: kernelServer.port, stateDir,
    });
    const schedulerServer = await listen(app);
    return { base: `http://127.0.0.1:${schedulerServer.port}`, close: () => { stop(); kernelServer.server.close(); schedulerServer.server.close(); } };
  }

  async function seed(stateDir: string, sid: string, schedule: Record<string, unknown>): Promise<void> {
    await mkdir(stateDir, { recursive: true });
    const now = new Date().toISOString();
    await writeFile(path.join(stateDir, `${sid}.json`), JSON.stringify({
      v: 2, sessionId: sid, mode: 'standard', messages: [], pendingApproval: null,
      createdAt: now, updatedAt: now, schedules: [schedule],
    }), 'utf8');
  }

  it('does not fire a schedule dated months ahead', async () => {
    const stateDir = path.join(dir, 'future');
    await seed(stateDir, 'future-1', {
      id: 'sch-1', prompt: 'new year', at: '2030-01-01T01:00:00.000Z', status: 'active', runs: 0,
    });
    const app = await boot(stateDir);
    await wait(250);
    const rec = await readRecord(stateDir, 'future-1');
    expect(scheduleOf(rec).status).toBe('active');
    expect(Number(scheduleOf(rec).runs ?? 0)).toBe(0);
    app.close();
  });

  it('catches up a stale repeating schedule once and moves it forward', async () => {
    const stateDir = path.join(dir, 'repeat');
    const twoDaysAgo = new Date(Date.now() - 2 * 24 * 3600_000).toISOString();
    await seed(stateDir, 'repeat-1', {
      id: 'sch-1', prompt: 'tick', at: twoDaysAgo, repeatMs: 60_000, status: 'active', runs: 0,
    });
    const app = await boot(stateDir);
    await wait(300);
    const rec = await readRecord(stateDir, 'repeat-1');
    const sched = scheduleOf(rec);
    // fired exactly once for the missed slot …
    expect(Number(sched.runs)).toBeGreaterThanOrEqual(1);
    expect(Number(sched.runs)).toBeLessThanOrEqual(2);
    // … and the cursor is now in the future, not stuck two days back
    const next = new Date(String(sched.at)).getTime();
    expect(next).toBeGreaterThan(Date.now() - 1000);
    expect(sched.status).toBe('active');
    app.close();
  });
});
