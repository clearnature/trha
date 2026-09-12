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

import { spawn } from 'node:child_process';
import * as path from 'node:path';
import * as fs from 'node:fs';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, '../../../..');
const schedulerEntry = path.join(repoRoot, 'packages/scheduler/dist/cli.js');

const TOKEN = 'e2e-smoke-token';
const PORT = Number(process.env.E2E_PORT ?? 3479);
const BASE = `http://127.0.0.1:${PORT}`;

const log = (...a) => console.log('[e2e]', ...a);
const fail = (msg) => { console.error('[e2e] FAIL:', msg); process.exitCode = 1; };
const assert = (cond, msg) => { if (!cond) { fail(msg); } else { log('ok:', msg); } };

const authHeaders = { Authorization: `Bearer ${TOKEN}`, 'Content-Type': 'application/json' };

async function getJson(pathname) {
  const res = await fetch(`${BASE}${pathname}`, { headers: authHeaders });
  return { status: res.status, body: await res.json().catch(() => null) };
}

const sleep = (ms) => new Promise(r => setTimeout(r, ms));

async function waitForHealth(timeoutMs = 15000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const res = await fetch(`${BASE}/health`);
      if (res.ok) return await res.json();
    } catch { /* not up yet */ }
    await sleep(200);
  }
  throw new Error(`scheduler did not become healthy within ${timeoutMs}ms`);
}

function startScheduler() {
  if (!fs.existsSync(schedulerEntry)) {
    throw new Error(`scheduler entry not found: ${schedulerEntry} (run the scheduler build first)`);
  }
  const child = spawn(process.execPath, [schedulerEntry], {
    env: { ...process.env, TRHA_TOKEN: TOKEN, TRHA_PORT: String(PORT), TRHA_LEASE_STDIN: '1' },
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

async function main() {
  log(`scheduler entry: ${schedulerEntry}`);
  const { child, handshake } = startScheduler();

  const line = await handshake;
  let hs;
  try { hs = JSON.parse(line); } catch { throw new Error(`handshake is not JSON: ${line}`); }
  assert(hs.v === 1, `handshake version is 1 (got ${hs.v})`);
  assert(hs.name === 'trha-scheduler', `handshake name is trha-scheduler (got ${hs.name})`);
  assert(typeof hs.port === 'number', `handshake carries a numeric port (got ${hs.port})`);

  await waitForHealth();
  assert(true, 'GET /health is 200');

  const modes = await getJson('/api/modes');
  assert(modes.status === 200 && modes.body && typeof modes.body === 'object',
    `GET /api/modes returns a mode table (status ${modes.status})`);

  const models = await getJson('/api/models');
  assert(models.status === 200 && Array.isArray(models.body),
    `GET /api/models returns a list (status ${models.status})`);

  // Loopback origin-less reads are allowed by design; writes require Bearer.
  const unauthRead = await fetch(`${BASE}/api/sessions`);
  assert(unauthRead.status === 200, `loopback origin-less read is allowed (got ${unauthRead.status})`);

  const unauthWrite = await fetch(`${BASE}/api/session/start`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ mode: 'standard' }),
  });
  assert(unauthWrite.status === 401, `write without a token is 401 (got ${unauthWrite.status})`);

  const created = await fetch(`${BASE}/api/session/start`, {
    method: 'POST', headers: authHeaders, body: JSON.stringify({ mode: 'standard' }),
  });
  const createdBody = await created.json().catch(() => null);
  assert(created.ok && createdBody?.sessionId, `POST /api/session/start creates a session (${createdBody?.sessionId})`);

  const sessions = await getJson('/api/sessions');
  assert(sessions.status === 200 && Array.isArray(sessions.body), 'GET /api/sessions lists sessions');

  const messages = await getJson(`/api/session/${createdBody.sessionId}/messages`);
  assert(messages.status === 200, 'GET /api/session/:id/messages is reachable');

  const deleted = await fetch(`${BASE}/api/session/${createdBody.sessionId}`, {
    method: 'DELETE', headers: authHeaders,
  });
  assert(deleted.status === 200, `DELETE /api/session/:id succeeds (status ${deleted.status})`);

  // Release the stdin lease; the child must drain and exit 0.
  const exitCode = await new Promise((resolve) => {
    child.on('exit', (code) => resolve(code));
    child.stdin.end();
    setTimeout(() => { child.kill(); resolve('timeout'); }, 8000);
  });
  assert(exitCode === 0, `scheduler exits 0 after the lease is released (got ${exitCode})`);

  log(process.exitCode ? 'RESULT: FAIL' : 'RESULT: PASS');
}

main().catch(err => { fail(err.message); });
