// End-to-end checks for POST /api/sandbox/experiment (T2.7): the scheduling
// seam entry. Uses the real createServer plus the mock runner fixture, so the
// validation, the seam switch and the outcome shape are exercised together —
// exactly what the CLI (Bridge.submitExperiment) will hit.
import { chmodSync, mkdtempSync, rmSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import type { Server } from 'node:http';
import type { AddressInfo } from 'node:net';
import type { Express } from 'express';
import { createServer } from '../src/Server/index.js';

const fixture = path.join(
  path.dirname(fileURLToPath(import.meta.url)),
  'fixtures', 'mock-sandbox-runner.mjs',
);

async function listen(app: Express): Promise<{ base: string; server: Server }> {
  const server = await new Promise<Server>((resolve) => {
    const s = app.listen(0, '127.0.0.1', () => resolve(s));
  });
  const { port } = server.address() as AddressInfo;
  return { base: `http://127.0.0.1:${port}`, server };
}

const json = { Authorization: 'Bearer dev-token', 'Content-Type': 'application/json' } as Record<string, string>;

describe('POST /api/sandbox/experiment', () => {
  it('refuses while the sandbox seam is off', async () => {
    const { app } = createServer({ port: 0, token: 'dev-token' });
    const { base, server } = await listen(app);
    try {
      const res = await fetch(`${base}/api/sandbox/experiment`, {
        method: 'POST', headers: json,
        body: JSON.stringify({ id: 'x', root: '/tmp/x', baseline: '/tmp/x/b', variants: [{ id: 'a' }], seeds: [1], command: ['true'] }),
      });
      expect(res.status).toBe(503);
      const body = await res.json();
      expect(body.error).toContain('TRHA_SANDBOX is off');
    } finally {
      server.close();
    }
  });

  it('rejects a malformed batch before spawning anything', async () => {
    delete process.env.TRHA_SANDBOX; // seam off anyway: validation precedes the switch
    const { app } = createServer({ port: 0, token: 'dev-token' });
    const { base, server } = await listen(app);
    try {
      const cases: Array<{ body: Record<string, unknown>; why: string }> = [
        { body: { id: 'x' }, why: 'missing root/baseline' },
        { body: { id: 'x', root: '/t', baseline: '/b', variants: [], seeds: [1], command: ['true'] }, why: 'empty variants' },
        { body: { id: 'x', root: '/t', baseline: '/b', variants: [{ id: 'a' }], seeds: [1.5], command: ['true'] }, why: 'non-integer seed' },
        { body: { id: 'x', root: '/t', baseline: '/b', variants: [{ id: 'a' }], seeds: [1], command: [] }, why: 'empty command' },
        { body: { id: 'x', root: '/t', baseline: '/b', variants: [{ id: 'a' }], seeds: [1], command: ['true'], concurrency: 99 }, why: 'concurrency out of bounds' },
        { body: { id: 'x', root: '/t', baseline: '/b', variants: [{ id: 'a' }], seeds: [1], command: ['true'], retries: 9 }, why: 'retries out of bounds' },
      ];
      for (const c of cases) {
        const res = await fetch(`${base}/api/sandbox/experiment`, {
          method: 'POST', headers: json, body: JSON.stringify(c.body),
        });
        expect(res.status, c.why).toBe(400);
      }
    } finally {
      server.close();
    }
  });

  it('runs the matrix end to end and reports an outcome with a reproPath', async () => {
    chmodSync(fixture, 0o755);
    const prevSandbox = process.env.TRHA_SANDBOX;
    const prevRunner = process.env.TRHA_SANDBOX_RUNNER;
    process.env.TRHA_SANDBOX = 'on';
    process.env.TRHA_SANDBOX_RUNNER = fixture;
    const { app } = createServer({ port: 0, token: 'dev-token' });
    const { base, server } = await listen(app);
    const root = mkdtempSync(path.join(os.tmpdir(), 'trha-exp-api-'));
    try {
      const res = await fetch(`${base}/api/sandbox/experiment`, {
        method: 'POST', headers: json,
        body: JSON.stringify({
          id: 'e2e', root, baseline: path.join(root, 'baseline'),
          variants: [{ id: 'a' }, { id: 'b' }], seeds: [1],
          concurrency: 2, command: ['echo', 'x'],
        }),
      });
      expect(res.status).toBe(200);
      const outcome = (await res.json()) as {
        batchId: string; reproPath: string;
        results: Array<{ variant: string; seed: number; ok: boolean }>;
      };
      expect(outcome.batchId).toBe('e2e');
      expect(outcome.reproPath).toBe(path.join(root, 'repro.json'));
      expect(outcome.results.map(r => r.variant).sort()).toEqual(['a', 'b']);
      expect(outcome.results.every(r => r.ok)).toBe(true);
    } finally {
      server.close();
      process.env.TRHA_SANDBOX = prevSandbox;
      process.env.TRHA_SANDBOX_RUNNER = prevRunner;
      rmSync(root, { recursive: true, force: true });
    }
  });
});
