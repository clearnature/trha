#!/usr/bin/env node
// Desktop E2E smoke test (protocol level).
//
// The full UI smoke would need a GUI-capable Electron host, which this
// environment does not provide, so per the execution plan (rule 4.2) this
// degrades to a protocol-level check of the exact chain the desktop shell
// uses at runtime:
//   1. spawn the scheduler the same way main/index.ts does (handshake on
//      stdout, token via env, stdin lease);
//   2. assert the versioned single-line handshake;
//   3. drive the session API surface the port layer consumes (health, modes,
//      models, session start/list, messages) with the Bearer token;
//   4. release the stdin lease and assert the child exits 0.
//
// Exit code 0 = all assertions passed; non-zero = first failure.
//
// collectProtocol() is also used by test/protocol-snapshot.test.ts to record
// the response *shape* (field names + types) as a fixture.

import { spawn } from 'node:child_process';
import * as path from 'node:path';
import * as fs from 'node:fs';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, '../../../..');
const schedulerEntry = path.join(repoRoot, 'packages/scheduler/dist/cli.js');

export const DEFAULT_PORT = Number(process.env.E2E_PORT ?? 3479);
export const DEFAULT_TOKEN = 'e2e-smoke-token';

const log = (...a) => console.log('[e2e]', ...a);
const fail = (msg) => { console.error('[e2e] FAIL:', msg); process.exitCode = 1; };
const assert = (cond, msg) => { if (!cond) { fail(msg); } else { log('ok:', msg); } };

const sleep = (ms) => new Promise(r => setTimeout(r, ms));

function authHeaders(token) {
  return { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' };
}

async function getJson(base, pathname, headers) {
  const res = await fetch(`${base}${pathname}`, { headers });
  return { status: res.status, body: await res.json().catch(() => null) };
}

async function waitForHealth(base, timeoutMs = 15000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const res = await fetch(`${base}/health`);
      if (res.ok) return await res.json();
    } catch { /* not up yet */ }
    await sleep(200);
  }
  throw new Error(`scheduler did not become healthy within ${timeoutMs}ms`);
}

function startScheduler({ port, token }) {
  if (!fs.existsSync(schedulerEntry)) {
    throw new Error(`scheduler entry not found: ${schedulerEntry} (run the scheduler build first)`);
  }
  const child = spawn(process.execPath, [schedulerEntry], {
    env: { ...process.env, TRHA_TOKEN: token, TRHA_PORT: String(port), TRHA_LEASE_STDIN: '1' },
    stdio: ['pipe', 'pipe', 'pipe'],
  });
  const handshake = new Promise((resolve, reject) => {
    let head = '';
    child.stdout.on('data', d => {
      head += d.toString();
      const nl = head.indexOf('\n');
      if (nl !== -1) resolve(head.slice(0, nl));
    });
    child.on('error', reject);
    setTimeout(() => reject(new Error('handshake timeout (5s)')), 5000);
  });
  child.stderr.on('data', d => log('scheduler:', d.toString().trimEnd()));
  return { child, handshake };
}

/**
 * Drive the same protocol surface the desktop shell uses and return the raw
 * responses. Throws if the scheduler is missing or never becomes healthy.
 *
 * @param {{ port?: number, token?: string }} [opts]
 */
export async function collectProtocol({ port = DEFAULT_PORT, token = DEFAULT_TOKEN } = {}) {
  const base = `http://127.0.0.1:${port}`;
  const headers = authHeaders(token);
  const { child, handshake } = startScheduler({ port, token });

  const line = await handshake;
  const hs = JSON.parse(line);

  await waitForHealth(base);

  const health = await getJson(base, '/health', headers);
  const modes = await getJson(base, '/api/modes', headers);
  const models = await getJson(base, '/api/models', headers);

  const unauthRead = await fetch(`${base}/api/sessions`);
  const unauthWrite = await fetch(`${base}/api/session/start`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ mode: 'standard' }),
  });

  const created = await fetch(`${base}/api/session/start`, {
    method: 'POST', headers, body: JSON.stringify({ mode: 'standard' }),
  });
  const createdBody = await created.json().catch(() => null);

  const sessions = await getJson(base, '/api/sessions', headers);
  const messages = await getJson(base, `/api/session/${createdBody?.sessionId}/messages`, headers);

  const deleted = await fetch(`${base}/api/session/${createdBody?.sessionId}`, {
    method: 'DELETE', headers,
  });

  const exitCode = await new Promise((resolve) => {
    child.on('exit', (code) => resolve(code));
    child.stdin.end();
    setTimeout(() => { child.kill(); resolve('timeout'); }, 8000);
  });

  return {
    handshake: hs,
    health: health.body,
    modes: modes.body,
    models: models.body,
    session: createdBody,
    sessions: sessions.body,
    messages: messages.body,
    http: {
      health: health.status,
      modes: modes.status,
      models: models.status,
      unauthRead: unauthRead.status,
      unauthWrite: unauthWrite.status,
      createSession: created.status,
      sessions: sessions.status,
      messages: messages.status,
      deleteSession: deleted.status,
    },
    exitCode,
  };
}

async function main() {
  log(`scheduler entry: ${schedulerEntry}`);
  const snap = await collectProtocol();

  assert(snap.handshake.v === 1, `handshake version is 1 (got ${snap.handshake.v})`);
  assert(snap.handshake.name === 'trha-scheduler', `handshake name is trha-scheduler (got ${snap.handshake.name})`);
  assert(typeof snap.handshake.port === 'number', `handshake carries a numeric port (got ${snap.handshake.port})`);

  assert(snap.http.health === 200, 'GET /health is 200');
  assert(snap.http.modes === 200 && snap.modes && typeof snap.modes === 'object',
    `GET /api/modes returns a mode table (status ${snap.http.modes})`);
  assert(snap.http.models === 200 && Array.isArray(snap.models),
    `GET /api/models returns a list (status ${snap.http.models})`);

  // Loopback origin-less reads are allowed by design; writes require Bearer.
  assert(snap.http.unauthRead === 200, `loopback origin-less read is allowed (got ${snap.http.unauthRead})`);
  assert(snap.http.unauthWrite === 401, `write without a token is 401 (got ${snap.http.unauthWrite})`);

  assert(snap.http.createSession === 200 && snap.session?.sessionId,
    `POST /api/session/start creates a session (${snap.session?.sessionId})`);
  assert(snap.http.sessions === 200 && Array.isArray(snap.sessions), 'GET /api/sessions lists sessions');
  assert(snap.http.messages === 200, 'GET /api/session/:id/messages is reachable');
  assert(snap.http.deleteSession === 200, `DELETE /api/session/:id succeeds (status ${snap.http.deleteSession})`);
  assert(snap.exitCode === 0, `scheduler exits 0 after the lease is released (got ${snap.exitCode})`);

  log(process.exitCode ? 'RESULT: FAIL' : 'RESULT: PASS');
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch(err => { fail(err.message); });
}
