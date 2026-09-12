// P6: a request that names a provider is answered by that provider's own
// endpoint.  The kernel's chat completions handler must dispatch on the
// "provider" field; a name it does not know is a coded 404, not a fallback.

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
const KERNEL_PORT = 8097;
const STUB_PORT = 8093;
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

describe('provider dispatch (P6)', () => {
  it.runIf(!enabled)('is skipped unless KERNEL_BUILD=1', () => {
    expect(true).toBe(true);
  });

  it.runIf(enabled)('answers a named provider through its own endpoint', async () => {
    execFileSync('cabal', ['build', 'trha:exe:trha'],
      { cwd: repoRoot, stdio: 'inherit', timeout: 900_000 });
    const bin = trhaBin();
    expect(bin, 'built trha executable').toBeTruthy();

    // A stub that answers as any OpenAI-compatible endpoint would.
    const seenBodies: unknown[] = [];
    const seenUrls: string[] = [];
    const seenHeaders: Record<string, string>[] = [];
    const stub: Server = createServer((req, res) => {
      let body = '';
      req.on('data', c => { body += c; });
      req.on('end', () => {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        if (req.url === '/models') {
          res.end(JSON.stringify({ data: [{ id: 'stub-chat' }] }));
          return;
        }
        seenUrls.push(req.url ?? '');
        seenHeaders.push(req.headers as Record<string, string>);
        seenBodies.push(JSON.parse(body || '{}'));
        if (req.url === '/v1/messages') {
          res.end(JSON.stringify({
            content: [{ type: 'text', text: 'answered by the anthropic stub' }],
            usage: { input_tokens: 1, output_tokens: 2 },
          }));
          return;
        }
        if (req.url === '/v1/responses') {
          res.end(JSON.stringify({
            output: [
              { type: 'message', content: [{ type: 'output_text', text: 'answered by the responses stub' }] },
            ],
            usage: { input_tokens: 1, output_tokens: 2 },
          }));
          return;
        }
        res.end(JSON.stringify({
          choices: [{ index: 0, message: { role: 'assistant', content: 'answered by the stub provider' } }],
          usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 },
        }));
      });
    });
    await new Promise<void>(resolve => stub.listen(STUB_PORT, '127.0.0.1', () => resolve()));

    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'trha-disp-'));
    const kernel: ChildProcess = spawn(bin as string, ['serve', '-p', String(KERNEL_PORT)], {
      stdio: ['pipe', 'pipe', 'pipe'],
      env: {
        ...process.env,
        TRHA_PROVIDERS_FILE: path.join(tmpDir, 'providers.json'),
        TRHA_PROVIDER_KEYS_FILE: path.join(tmpDir, 'keys.json'),
      },
    });

    try {
      expect(await waitHealth(KERNEL_PORT), 'kernel health').toBe(true);
      const json = { 'Content-Type': 'application/json' };

      // Save the stub as a provider, then aim a chat request at it.
      const saved = await fetch(`http://127.0.0.1:${KERNEL_PORT}/providers`, {
        method: 'POST', headers: json,
        body: JSON.stringify({
          name: 'stub', kind: 'openai', baseUrl: `http://127.0.0.1:${STUB_PORT}`,
          apiKey: 'k', models: ['stub-chat'], default: 'stub-chat',
        }),
      }).then(r => r.json()) as { providers: unknown[] };
      expect(saved.providers).toHaveLength(1);

      const chat = await fetch(`http://127.0.0.1:${KERNEL_PORT}/v1/chat/completions`, {
        method: 'POST', headers: json,
        body: JSON.stringify({
          model: 'stub-chat', provider: 'stub',
          messages: [{ role: 'user', content: 'hi' }],
        }),
      }).then(r => r.json()) as { choices: { message: { content: string } }[] };

      expect(chat.choices[0].message.content).toContain('stub provider');
      expect(seenBodies).toHaveLength(1);
      // The model the panel picked is the model the endpoint was asked for.
      expect((seenBodies[0] as { model?: string }).model).toBe('stub-chat');

      // ── Anthropic wire: x-api-key + version header + max_tokens ──────
      await fetch(`http://127.0.0.1:${KERNEL_PORT}/providers`, {
        method: 'POST', headers: json,
        body: JSON.stringify({
          name: 'anth', kind: 'anthropic', baseUrl: `http://127.0.0.1:${STUB_PORT}`,
          apiKey: 'anth-key', models: ['stub-chat'], default: 'stub-chat',
        }),
      });
      const anth = await fetch(`http://127.0.0.1:${KERNEL_PORT}/v1/chat/completions`, {
        method: 'POST', headers: json,
        body: JSON.stringify({ model: 'stub-chat', provider: 'anth', messages: [{ role: 'user', content: 'hi' }] }),
      }).then(r => r.json()) as { choices: { message: { content: string } }[] };
      expect(anth.choices[0].message.content).toContain('anthropic stub');
      expect(seenUrls.at(-1)).toBe('/v1/messages');
      expect(seenHeaders.at(-1)?.['x-api-key']).toBe('anth-key');
      expect(seenHeaders.at(-1)?.['anthropic-version']).toBe('2023-06-01');
      expect((seenBodies.at(-1) as { max_tokens?: number }).max_tokens).toBeGreaterThan(0);

      // ── Responses wire: input items + function_call shape ────────────
      await fetch(`http://127.0.0.1:${KERNEL_PORT}/providers`, {
        method: 'POST', headers: json,
        body: JSON.stringify({
          name: 'resp', kind: 'responses', baseUrl: `http://127.0.0.1:${STUB_PORT}`,
          apiKey: 'resp-key', models: ['stub-chat'], default: 'stub-chat',
        }),
      });
      const resp = await fetch(`http://127.0.0.1:${KERNEL_PORT}/v1/chat/completions`, {
        method: 'POST', headers: json,
        body: JSON.stringify({ model: 'stub-chat', provider: 'resp', messages: [{ role: 'user', content: 'hi' }] }),
      }).then(r => r.json()) as { choices: { message: { content: string } }[] };
      expect(resp.choices[0].message.content).toContain('responses stub');
      expect(seenUrls.at(-1)).toBe('/v1/responses');
      expect(seenHeaders.at(-1)?.['authorization']).toBe('Bearer resp-key');
      expect(Array.isArray((seenBodies.at(-1) as { input?: unknown[] }).input)).toBe(true);

      // An unknown provider is a coded refusal, not a silent default.
      const unknown = await fetch(`http://127.0.0.1:${KERNEL_PORT}/v1/chat/completions`, {
        method: 'POST', headers: json,
        body: JSON.stringify({ model: 'x', provider: 'nope', messages: [{ role: 'user', content: 'hi' }] }),
      });
      expect(unknown.status).toBe(404);
      expect((await unknown.json() as { code: string }).code).toBe('provider.unknown');
    } finally {
      kernel.kill('SIGTERM');
      await new Promise<void>(resolve => stub.close(() => resolve()));
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  }, 300_000);
});
