// P2 smoke: probe a local endpoint through the kernel's /providers/probe.
//
//   kernel (trha serve)  ←  POST /providers/probe {baseUrl, apiKey}
//   a local stub server answers GET /models with an OpenAI-style listing.
//
// Guards on KERNEL_BUILD=1 like the other kernel tests.

import { describe, it, expect } from 'vitest';
import { execFileSync, spawn } from 'node:child_process';
import type { ChildProcess } from 'node:child_process';
import { createServer } from 'node:http';
import type { Server } from 'node:http';
import * as path from 'node:path';
import * as fs from 'node:fs';
import * as os from 'node:os';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(here, '../../../..');
const KERNEL_PORT = 8080;
const STUB_PORT = 8091;
const enabled = process.env.KERNEL_BUILD === '1';

const sleep = (ms: number) => new Promise(r => setTimeout(r, ms));

async function waitHealth(port: number, timeoutMs = 20000): Promise<boolean> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try { const r = await fetch(`http://127.0.0.1:${port}/health`); if (r.ok) return true; } catch { /* not up */ }
    await sleep(200);
  }
  return false;
}

function trhaBin(): string | null {
  try {
    return execFileSync('cabal', ['list-bin', 'trha:exe:trha'],
      { cwd: repoRoot, encoding: 'utf8' }).trim() || null;
  } catch { return null; }
}

describe('provider probe (P2)', () => {
  it.runIf(!enabled)('is skipped unless KERNEL_BUILD=1', () => {
    expect(true).toBe(true);
  });

  it.runIf(enabled)('probes a local OpenAI-style endpoint and returns its models', async () => {
    expect(fs.existsSync(path.join(repoRoot, 'cabal.project'))).toBe(true);
    execFileSync('cabal', ['build', 'trha:exe:trha'],
      { cwd: repoRoot, stdio: 'inherit', timeout: 900_000 });

    const bin = trhaBin();
    expect(bin, 'built trha executable').toBeTruthy();

    const stub: Server = createServer((req, res) => {
      if (req.url === '/models') {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ data: [{ id: 'stub-a' }, { id: 'stub-b' }] }));
      } else {
        res.writeHead(404, { 'Content-Type': 'application/json' });
        res.end('{}');
      }
    });
    await new Promise<void>(resolve => stub.listen(STUB_PORT, '127.0.0.1', () => resolve()));

    // Keep the run away from the user's real ~/.trha.
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'trha-prov-'));
    const providersFile = path.join(tmpDir, 'providers.json');
    const keysFile = path.join(tmpDir, 'keys.json');
    const kernel: ChildProcess = spawn(bin as string, ['serve', '-p', String(KERNEL_PORT)],
      { stdio: ['pipe', 'pipe', 'pipe'],
        env: { ...process.env, TRHA_PROVIDERS_FILE: providersFile, TRHA_PROVIDER_KEYS_FILE: keysFile } });
    try {
      expect(await waitHealth(KERNEL_PORT), 'kernel health').toBe(true);

      const probe = await fetch(`http://127.0.0.1:${KERNEL_PORT}/providers/probe`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ baseUrl: `http://127.0.0.1:${STUB_PORT}`, apiKey: 'k' }),
      }).then(r => r.json()) as { kind: string; models: string[]; default: string; noProxy: boolean };

      expect(probe.kind).toBe('openai');
      expect(probe.models).toEqual(['stub-a', 'stub-b']);
      expect(probe.default).toBe('stub-a');
      expect(probe.noProxy).toBe(false);

      // A path the endpoint does not serve is a coded 404, not a crash.
      const missing = await fetch(`http://127.0.0.1:${KERNEL_PORT}/providers/probe`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ baseUrl: `http://127.0.0.1:${STUB_PORT}/nope`, apiKey: 'k' }),
      });
      expect(missing.status).toBe(404);
      expect((await missing.json() as { code: string }).code).toBe('provider.path_missing');

      // P3: save -> list -> check -> remove; the key never lands in the config.
      const save = await fetch(`http://127.0.0.1:${KERNEL_PORT}/providers`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          name: 'stub', kind: 'openai', baseUrl: `http://127.0.0.1:${STUB_PORT}`,
          apiKey: 'sk-secret', models: ['stub-a', 'stub-b'], default: 'stub-a',
        }),
      }).then(r => r.json()) as { providers: { name: string; keyEnv?: string; hasKey: boolean }[] };
      expect(save.providers.map(p => p.name)).toEqual(['stub']);
      expect(save.providers[0].keyEnv).toBe('STUB_API_KEY');
      expect(save.providers[0].hasKey).toBe(true);

      // A name that could not be a config key is refused, not silently kept.
      const badName = await fetch(`http://127.0.0.1:${KERNEL_PORT}/providers`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ name: 'bad name', kind: 'openai', baseUrl: 'http://127.0.0.1:1' }),
      });
      expect(badName.status).toBe(400);
      expect((await badName.json() as { code: string }).code).toBe('provider.bad_name');

      const config = fs.readFileSync(providersFile, 'utf8');
      expect(config).not.toContain('sk-secret');
      expect(fs.readFileSync(keysFile, 'utf8')).toContain('sk-secret');

      const check = await fetch(`http://127.0.0.1:${KERNEL_PORT}/providers/check`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ name: 'stub' }),
      }).then(r => r.json()) as { ok: boolean; kind?: string; models?: string[] };
      expect(check.ok).toBe(true);
      expect(check.models).toEqual(['stub-a', 'stub-b']);

      // P8: an edit keeps what it does not mention; the toggles flip one field.
      const edited = await fetch(`http://127.0.0.1:${KERNEL_PORT}/providers/edit`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ name: 'stub', default: 'stub-b' }),
      }).then(r => r.json()) as { providers: { default: string; models: string[]; keyEnv?: string }[] };
      expect(edited.providers[0].default).toBe('stub-b');
      expect(edited.providers[0].models).toEqual(['stub-a', 'stub-b']);
      expect(edited.providers[0].keyEnv).toBe('STUB_API_KEY');

      const toggled = await fetch(`http://127.0.0.1:${KERNEL_PORT}/providers/websearch`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ name: 'stub', on: true }),
      }).then(r => r.json()) as { providers: { webSearch?: boolean }[] };
      expect(toggled.providers[0].webSearch).toBe(true);

      const thinking = await fetch(`http://127.0.0.1:${KERNEL_PORT}/providers/thinking`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ name: 'stub', on: true }),
      }).then(r => r.json()) as { providers: { sendsThinking?: boolean }[] };
      expect(thinking.providers[0].sendsThinking).toBe(true);

      const removed = await fetch(`http://127.0.0.1:${KERNEL_PORT}/providers/remove`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ name: 'stub' }),
      }).then(r => r.json()) as { providers: unknown[] };
      expect(removed.providers).toHaveLength(0);
    } finally {
      kernel.kill('SIGTERM');
      await new Promise<void>(resolve => stub.close(() => resolve()));
    }
  }, 300_000);
});
