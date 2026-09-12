#!/usr/bin/env node
// Dev stack launcher: bring up the whole desktop chain in one command.
//
//   kernel (API server on 8080)  ←  scheduler (3456)  ←  Desktop / CLI / TUI
//
// The kernel entry defaults to the already-built `trha-kernel-stub`
// (deterministic two-round tool loop, no LLM key required).  Once an LLM key
// is configured you can point KERNEL_BIN at the real `trha serve` binary
// instead -- the scheduler does not care which one answers on 8080.
//
// Usage:  node packages/app/Desktop/scripts/dev-stack.mjs
//         KERNEL_PORT=8080 SCHED_PORT=3456 KERNEL_BIN=... node .../dev-stack.mjs

import { spawn } from 'node:child_process';
import * as path from 'node:path';
import * as fs from 'node:fs';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, '../../../..');

const KERNEL_PORT = Number(process.env.KERNEL_PORT ?? 8080);
const SCHED_PORT = Number(process.env.SCHED_PORT ?? 3456);
const TOKEN = process.env.TRHA_TOKEN ?? 'dev-token';

function kernelBin() {
  if (process.env.KERNEL_BIN) return process.env.KERNEL_BIN;
  const dist = path.join(repoRoot, 'dist-newstyle');
  const found = fs.existsSync(dist) ? findStub(dist) : null;
  return found ?? path.join(repoRoot, 'dist-newstyle', 'build', '<platform>', 'trha-kernel-stub');
}

function findStub(dir) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      const hit = findStub(p);
      if (hit) return hit;
    } else if (entry.name === 'trha-kernel-stub' && (fs.statSync(p).mode & 0o111)) {
      return p;
    }
  }
  return null;
}

const children = [];
function start(name, cmd, args, env) {
  const child = spawn(cmd, args, { env: { ...process.env, ...env }, stdio: ['pipe', 'pipe', 'pipe'] });
  child.stderr.on('data', d => process.stderr.write(`[${name}] ${d}`));
  child.on('exit', code => console.log(`[${name}] exited (${code})`));
  children.push({ name, child });
  return child;
}

function shutdown() {
  for (const { child } of children) {
    child.stdin?.end();          // scheduler lsat: lease via stdin
    child.kill('SIGTERM');
  }
  process.exit(0);
}
process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);

// ── kernel ─────────────────────────────────────────────────────────────
const bin = kernelBin();
if (!fs.existsSync(bin)) {
  console.error(`[kernel] not found: ${bin}\n` +
    '  build it first:  cabal build exe:trha-kernel-stub\n' +
    '  or point KERNEL_BIN at a built binary');
  process.exit(1);
}
const kernel = start('kernel', bin, [String(KERNEL_PORT)], {});
kernel.stdout.on('data', d => process.stdout.write(`[kernel] ${d}`));

// Wait for the kernel health endpoint before starting the scheduler.
async function waitHealth(url, timeoutMs = 15000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try { const r = await fetch(url); if (r.ok) return true; } catch { /* not up */ }
    await new Promise(r => setTimeout(r, 200));
  }
  return false;
}

const ok = await waitHealth(`http://127.0.0.1:${KERNEL_PORT}/health`);
if (!ok) {
  console.error(`[kernel] no /health on ${KERNEL_PORT} within 15s`);
  shutdown();
}
console.log(`[kernel] healthy on ${KERNEL_PORT}`);

// ── scheduler ──────────────────────────────────────────────────────────
const schedEntry = path.join(repoRoot, 'packages/scheduler/dist/cli.js');
const sched = start('scheduler', process.execPath, [schedEntry], {
  TRHA_TOKEN: TOKEN, TRHA_PORT: String(SCHED_PORT), TRHA_LEASE_STDIN: '1',
});
sched.stdout.on('data', d => process.stdout.write(`[scheduler] ${d}`));

const schedOk = await waitHealth(`http://127.0.0.1:${SCHED_PORT}/health`);
console.log(schedOk ? `[scheduler] healthy on ${SCHED_PORT}` : `[scheduler] health check failed on ${SCHED_PORT}`);

console.log(`
Stack up:
  kernel     http://127.0.0.1:${KERNEL_PORT}   (health: ${ok ? 'ok' : 'FAIL'})
  scheduler  http://127.0.0.1:${SCHED_PORT}   (health: ${schedOk ? 'ok' : 'FAIL'})
  token      ${TOKEN}
Launch the desktop shell (npm start in packages/app/Desktop) or the CLI/TUI now.
Ctrl-C stops everything.`);
