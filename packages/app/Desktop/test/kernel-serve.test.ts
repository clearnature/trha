// Kernel serve wiring check, run through the test runner.
//
//  1. build the root `trha` executable (this is what `trha serve` runs);
//  2. launch it as `trha serve -p <PORT>`;
//  3. assert the kernel's /health answers -- i.e. runServeMode really starts
//     API.Server instead of printing the old TODO stub;
//  4. run the full chain: `trha serve` kernel <- scheduler <- step request,
//     and assert the reply comes from the kernel (stub adapter tool loop),
//     not from the scheduler's "kernel unreachable" echo fallback.
//
// Skipped unless KERNEL_BUILD=1 so ordinary unit runs stay fast.

import { describe, it, expect } from 'vitest';
import { execFileSync, spawn } from 'node:child_process';
import type { ChildProcess } from 'node:child_process';
import * as path from 'node:path';
import * as fs from 'node:fs';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(here, '../../../..');
// Must match the scheduler's default kernel address (haskellPort 8080),
// otherwise the scheduler falls back to its "kernel unreachable" echo.
const KERNEL_PORT = 8080;
const SCHED_PORT = 3498;
const enabled = process.env.KERNEL_BUILD === '1';

function trhaBin(): string | null {
  // Authoritative path from cabal (avoids stale gh-harness-era binaries that
  // still sit in dist-newstyle).
  try {
    return execFileSync('cabal', ['list-bin', 'trha:exe:trha'],
      { cwd: repoRoot, encoding: 'utf8' }).trim() || null;
  } catch {
    return null;
  }
}

const sleep = (ms: number) => new Promise(r => setTimeout(r, ms));

async function waitHealth(port: number, timeoutMs = 20000): Promise<boolean> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try { const r = await fetch(`http://127.0.0.1:${port}/health`); if (r.ok) return true; } catch { /* not up */ }
    await sleep(200);
  }
  return false;
}

const children: ChildProcess[] = [];
function launch(cmd: string, args: string[], env: Record<string, string> = {}): ChildProcess {
  const child = spawn(cmd, args, { env: { ...process.env, ...env }, stdio: ['pipe', 'pipe', 'pipe'] });
  children.push(child);
  return child;
}

describe('trha serve wiring', () => {
  it.runIf(!enabled)('is skipped unless KERNEL_BUILD=1', () => {
    expect(true).toBe(true);
  });

  it.runIf(enabled)('trha serve starts the kernel API server', async () => {
    expect(fs.existsSync(path.join(repoRoot, 'cabal.project'))).toBe(true);
    // Build the whole project (both local packages: trha + trha-cli) -- this
    // also proves the rename and the `trha:trha-api` reference did not break
    // the CLI package.
    execFileSync('cabal', ['build', 'all'],
      { cwd: repoRoot, stdio: 'inherit', timeout: 900_000 });
    // The project's own hspec suite (provider registry + kernel logic).
    execFileSync('cabal', ['test', 'trha-test', '--test-show-details=direct'],
      { cwd: repoRoot, stdio: 'inherit', timeout: 900_000 });

    const bin = trhaBin();
    expect(bin, 'built trha executable').toBeTruthy();

    const child = launch(bin as string, ['serve', '-p', String(KERNEL_PORT)]);
    let log = '';
    child.stdout?.on('data', d => { log += d.toString(); });
    child.stderr?.on('data', d => { log += d.toString(); });

    try {
      const healthy = await waitHealth(KERNEL_PORT);
      expect(healthy, `kernel /health on ${KERNEL_PORT}; serve output: ${log.slice(0, 300)}`).toBe(true);
      expect(log).not.toContain('TODO: Implement API server startup');

      // P1: provider registry endpoints.
      const providers = await fetch(`http://127.0.0.1:${KERNEL_PORT}/providers`)
        .then(r => r.json()) as { providers: unknown[] };
      expect(Array.isArray(providers.providers), 'GET /providers returns a store').toBe(true);

      const protocols = await fetch(`http://127.0.0.1:${KERNEL_PORT}/providers/protocols`)
        .then(r => r.json()) as { kind: string }[];
      expect(protocols.map(p => p.kind)).toEqual(['openai', 'anthropic', 'responses', 'extension']);
    } finally {
      child.kill('SIGTERM');
    }
  }, 900_000);

  it.runIf(enabled)('the full chain answers a step through trha serve', async () => {
    const bin = trhaBin();
    expect(bin, 'built trha executable').toBeTruthy();

    const kernel = launch(bin as string, ['serve', '-p', String(KERNEL_PORT)]);
    expect(await waitHealth(KERNEL_PORT), 'kernel health').toBe(true);

    const schedEntry = path.join(repoRoot, 'packages/scheduler/dist/cli.js');
    const scheduler = launch(process.execPath, [schedEntry],
      { TRHA_TOKEN: 't', TRHA_PORT: String(SCHED_PORT), TRHA_LEASE_STDIN: '1' });
    expect(await waitHealth(SCHED_PORT), 'scheduler health').toBe(true);

    const headers = { Authorization: 'Bearer t', 'Content-Type': 'application/json' };
    try {
      const created = await fetch(`http://127.0.0.1:${SCHED_PORT}/api/session/start`, {
        method: 'POST', headers, body: JSON.stringify({ mode: 'minimal' }),
      }).then(r => r.json() as Promise<{ sessionId: string }>);

      const step = await fetch(`http://127.0.0.1:${SCHED_PORT}/api/agent/step`, {
        method: 'POST', headers,
        body: JSON.stringify({ sessionId: created.sessionId, message: 'hello chain' }),
      }).then(r => r.json() as Promise<{ reply: string; messages: { role: string }[] }>);

      // Kernel answered (stub adapter tool loop) -- not the scheduler echo fallback.
      expect(step.reply).toContain('[stub]');
      expect(step.reply).not.toContain('Received:');
      expect(step.messages.some(m => m.role === 'tool'), 'tool result in the transcript').toBe(true);

      // P4: the UI's door reaches the kernel's provider registry.
      const providers = await fetch(`http://127.0.0.1:${SCHED_PORT}/api/providers`, { headers })
        .then(r => r.json()) as { providers: unknown[] };
      expect(Array.isArray(providers.providers), 'scheduler forwards /api/providers to the kernel').toBe(true);

      const protocols = await fetch(`http://127.0.0.1:${SCHED_PORT}/api/providers/protocols`, { headers })
        .then(r => r.json()) as { kind: string }[];
      expect(protocols.map(p => p.kind)).toEqual(['openai', 'anthropic', 'responses', 'extension']);
    } finally {
      scheduler.stdin?.end();
      scheduler.kill('SIGTERM');
      kernel.kill('SIGTERM');
    }
  }, 300_000);
});
