// A2/A3: the streaming endpoints must be *real* SSE — the caller sees each
// increment as the provider produces it, not one aggregate JSON at the end.

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
const KERNEL_PORT = 8098;
const STUB_PORT = 8094;
const enabled = process.env.KERNEL_BUILD === '1';
// The stub holds the second half back for this long, so "the first frame
// arrived well before the stream ended" becomes a real observation.
const STUB_GAP_MS = 600;

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

/** Read an SSE response, noting how soon the first bytes showed up. */
async function readSse(r: Response): Promise<{ frames: string[]; firstByteMs: number; frameTimes: number[]; totalMs: number }> {
  const reader = r.body!.getReader();
  const decoder = new TextDecoder();
  const t0 = Date.now();
  let firstByteMs = -1;
  let buf = '';
  const frames: string[] = [];
  const frameTimes: number[] = [];
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    if (firstByteMs < 0) firstByteMs = Date.now() - t0;
    buf += decoder.decode(value, { stream: true });
    let i = buf.indexOf('\n\n');
    while (i >= 0) {
      frames.push(buf.slice(0, i));
      frameTimes.push(Date.now() - t0);
      buf = buf.slice(i + 2);
      i = buf.indexOf('\n\n');
    }
  }
  return { frames, firstByteMs, frameTimes, totalMs: Date.now() - t0 };
}

/** Every @data:@ payload of the named event type (no name = all of them). */
function payloads(frames: string[], eventName?: string): Record<string, unknown>[] {
  const out: Record<string, unknown>[] = [];
  for (const frame of frames) {
    const lines = frame.split('\n');
    const name = lines.find(l => l.startsWith('event: '))?.slice(7);
    if (eventName !== undefined && name !== eventName) continue;
    const data = lines.find(l => l.startsWith('data: '))?.slice(6);
    if (data === undefined || data === '[DONE]') continue;
    try { out.push(JSON.parse(data) as Record<string, unknown>); } catch { /* ignore */ }
  }
  return out;
}

const openAIText = (f: string[]) => payloads(f)
  .map(p => ((p.choices as { delta?: { content?: string } }[] | undefined)?.[0]?.delta?.content) ?? '')
  .join('');

const anthropicText = (f: string[]) => payloads(f, 'content_block_delta')
  .map(p => ((p.delta as { text?: string } | undefined)?.text) ?? '')
  .join('');

const responsesText = (f: string[]) => payloads(f, 'response.output_text.delta')
  .map(p => (p.delta as string | undefined) ?? '')
  .join('');

describe('provider streaming dispatch (A2/A3)', () => {
  it.runIf(!enabled)('is skipped unless KERNEL_BUILD=1', () => {
    expect(true).toBe(true);
  });

  it.runIf(enabled)('streams each wire incrementally, as SSE', async () => {
    execFileSync('cabal', ['build', 'trha:exe:trha'],
      { cwd: repoRoot, stdio: 'inherit', timeout: 900_000 });
    const bin = trhaBin();
    expect(bin, 'built trha executable').toBeTruthy();

    const seenUrls: string[] = [];
    const seenBodies: Record<string, unknown>[] = [];
    const stub: Server = createServer((req, res) => {
      let body = '';
      req.on('data', c => { body += c; });
      req.on('end', () => { void (async () => {
        seenUrls.push(req.url ?? '');
        seenBodies.push(JSON.parse(body || '{}') as Record<string, unknown>);
        res.writeHead(200, { 'Content-Type': 'text/event-stream' });

        if (req.url === '/v1/messages') {
          // A thinking block with its signature: the next tool round must
          // replay both verbatim.
          res.write('event: content_block_start\n');
          res.write(`data: ${JSON.stringify({ type: 'content_block_start', index: 0, content_block: { type: 'thinking', thinking: '' } })}\n\n`);
          res.write('event: content_block_delta\n');
          res.write(`data: ${JSON.stringify({ type: 'content_block_delta', index: 0, delta: { type: 'thinking_delta', thinking: 'weighing' } })}\n\n`);
          res.write('event: content_block_delta\n');
          res.write(`data: ${JSON.stringify({ type: 'content_block_delta', index: 0, delta: { type: 'signature_delta', signature: 'sig_stub' } })}\n\n`);
          res.write('event: content_block_stop\ndata: {"type":"content_block_stop","index":0}\n\n');
          res.write('event: content_block_delta\n');
          res.write(`data: ${JSON.stringify({ type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: 'Hi from anth' } })}\n\n`);
          await sleep(STUB_GAP_MS);
          res.write('event: content_block_start\n');
          res.write(`data: ${JSON.stringify({ type: 'content_block_start', index: 1, content_block: { type: 'tool_use', id: 'toolu_1', name: 'read_file' } })}\n\n`);
          res.write('event: content_block_delta\n');
          res.write(`data: ${JSON.stringify({ type: 'content_block_delta', index: 1, delta: { type: 'input_json_delta', partial_json: '{"path":' } })}\n\n`);
          res.write('event: content_block_delta\n');
          res.write(`data: ${JSON.stringify({ type: 'content_block_delta', index: 1, delta: { type: 'input_json_delta', partial_json: '"a.txt"}' } })}\n\n`);
          res.write('event: content_block_stop\ndata: {"type":"content_block_stop","index":1}\n\n');
          res.write('event: message_stop\ndata: {"type":"message_stop"}\n\n');
          res.end();
          return;
        }

        if (req.url === '/v1/responses') {
          res.write('event: response.output_text.delta\n');
          res.write(`data: ${JSON.stringify({ type: 'response.output_text.delta', delta: 'Hi from resp' })}\n\n`);
          await sleep(STUB_GAP_MS);
          res.write('event: response.output_item.added\n');
          res.write(`data: ${JSON.stringify({ type: 'response.output_item.added', item: { type: 'function_call', id: 'fc_1', name: 'read_file' } })}\n\n`);
          res.write('event: response.function_call_arguments.delta\n');
          res.write(`data: ${JSON.stringify({ type: 'response.function_call_arguments.delta', delta: '{"path":' })}\n\n`);
          res.write('event: response.function_call_arguments.delta\n');
          res.write(`data: ${JSON.stringify({ type: 'response.function_call_arguments.delta', delta: '"a.txt"}' })}\n\n`);
          res.write('event: response.function_call_arguments.done\ndata: {"type":"response.function_call_arguments.done"}\n\n');
          res.write('event: response.completed\ndata: {"type":"response.completed"}\n\n');
          res.end();
          return;
        }

        // OpenAI-compatible wire.
        res.write(`data: ${JSON.stringify({ choices: [{ delta: { content: 'Hello' } }] })}\n\n`);
        await sleep(STUB_GAP_MS);
        res.write(`data: ${JSON.stringify({ choices: [{ delta: { content: ' from stub' } }] })}\n\n`);
        res.write(`data: ${JSON.stringify({ choices: [{ delta: { tool_calls: [{ index: 0, id: 'call_1', function: { name: 'read_file', arguments: '{"path":' } }] } }] })}\n\n`);
        res.write(`data: ${JSON.stringify({ choices: [{ delta: { tool_calls: [{ index: 0, function: { arguments: '"a.txt"}' } }] } }] })}\n\n`);
        res.write('data: [DONE]\n\n');
        res.end();
      })(); });
    });
    await new Promise<void>(resolve => stub.listen(STUB_PORT, '127.0.0.1', () => resolve()));

    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'trha-stream-'));
    const kernel: ChildProcess = spawn(bin as string, ['serve', '--kernel-port', String(KERNEL_PORT)], {
      stdio: ['pipe', 'pipe', 'pipe'],
      env: {
        ...process.env,
        // The kernel links wgpu-native from the vendored tree; a bare spawn
        // does not inherit cabal's library path.
        LD_LIBRARY_PATH: [
          path.join(repoRoot, '3rdparty/wgpu-native/lib'),
          process.env.LD_LIBRARY_PATH,
        ].filter(Boolean).join(':'),
        TRHA_PROVIDERS_FILE: path.join(tmpDir, 'providers.json'),
        TRHA_PROVIDER_KEYS_FILE: path.join(tmpDir, 'keys.json'),
      },
    });

    try {
      expect(await waitHealth(KERNEL_PORT), 'kernel health').toBe(true);
      const json = { 'Content-Type': 'application/json' };

      await fetch(`http://127.0.0.1:${KERNEL_PORT}/providers`, {
        method: 'POST', headers: json,
        body: JSON.stringify({
          name: 'str', kind: 'openai', baseUrl: `http://127.0.0.1:${STUB_PORT}/v1`,
          apiKey: 'sk-stub', models: ['stub-chat'], default: 'stub-chat',
        }),
      });

      // ── OpenAI wire: text increments, then a tool call ───────────────
      const r1 = await fetch(`http://127.0.0.1:${KERNEL_PORT}/v1/chat/completions/stream`, {
        method: 'POST', headers: json,
        body: JSON.stringify({
          model: 'stub-chat', provider: 'str',
          messages: [{ role: 'user', content: 'hi' }],
          tools: [{ type: 'function', function: { name: 'read_file', description: 'read', parameters: { type: 'object' } } }],
        }),
      });
      expect(r1.headers.get('content-type'), 'real SSE, not a JSON blob').toContain('text/event-stream');
      const { frames: f1, firstByteMs: t1, frameTimes: ft1, totalMs: tot1 } = await readSse(r1);
      // eslint-disable-next-line no-console
      console.log('OPENAI timing: first=%d total=%d frames=%j', t1, tot1, ft1);
      expect(openAIText(f1)).toBe('Hello from stub');
      // The first frame arrived long before the stub finished.
      expect(t1).toBeLessThan(STUB_GAP_MS);
      expect(f1.join('\n')).toContain('data: [DONE]');
      const toolFrames = payloads(f1).flatMap(p =>
        ((p.choices as { delta?: { tool_calls?: { function: { name: string; arguments: string } }[] } }[] | undefined)?.[0]?.delta?.tool_calls) ?? []);
      expect(toolFrames.map(c => c.function.name).join('')).toBe('read_file');
      expect(toolFrames.map(c => c.function.arguments).join('')).toBe('{"path":"a.txt"}');
      expect(seenUrls.at(-1)).toBe('/v1/chat/completions');
      expect(seenBodies.at(-1)?.stream).toBe(true);
      // The tools the caller declared were carried through to the provider.
      expect(Array.isArray(seenBodies.at(-1)?.tools)).toBe(true);

      // ── Anthropic wire: named events, tool_use in fragments ─────────
      await fetch(`http://127.0.0.1:${KERNEL_PORT}/providers`, {
        method: 'POST', headers: json,
        body: JSON.stringify({
          name: 'anth', kind: 'anthropic', baseUrl: `http://127.0.0.1:${STUB_PORT}`,
          apiKey: 'anth-key', models: ['claude'], default: 'claude',
        }),
      });
      const r2 = await fetch(`http://127.0.0.1:${KERNEL_PORT}/v1/messages/stream`, {
        method: 'POST', headers: json,
        body: JSON.stringify({
          model: 'claude', provider: 'anth', messages: [{ role: 'user', content: 'hi' }],
          // The Anthropic endpoint takes Anthropic-shaped tools (input_schema).
          tools: [{ name: 'read_file', description: 'read', input_schema: { type: 'object' } }],
        }),
      });
      expect(r2.headers.get('content-type')).toContain('text/event-stream');
      const { frames: f2, firstByteMs: t2 } = await readSse(r2);
      expect(anthropicText(f2)).toBe('Hi from anth');
      expect(t2).toBeLessThan(STUB_GAP_MS);
      const anthTool = payloads(f2, 'content_block_start')
        .map(p => (p.content_block as { type?: string; id?: string; name?: string; input?: unknown } | undefined))
        .find(b => b?.type === 'tool_use');
      expect(anthTool?.name).toBe('read_file');
      expect(anthTool?.input).toEqual({ path: 'a.txt' });
      // The provider's tool_use id must survive: the next round's tool_result
      // needs it (DeepSeek rejects an empty tool_use_id with 400).
      expect(anthTool?.id).toBe('toolu_1');
      const anthDeltas = payloads(f2, 'content_block_delta')
        .map(p => p.delta as { type?: string; thinking?: string; signature?: string } | undefined);
      expect(anthDeltas.find(d => d?.type === 'thinking_delta')?.thinking).toBe('weighing');
      expect(anthDeltas.find(d => d?.type === 'signature_delta')?.signature).toBe('sig_stub');
      expect(seenUrls.at(-1)).toBe('/v1/messages');
      expect(seenBodies.at(-1)?.max_tokens).toBeGreaterThan(0);
      // Regression: without stream:true the endpoint answers one JSON body and
      // the SSE parser sees nothing (the reply silently disappeared).
      expect(seenBodies.at(-1)?.stream).toBe(true);
      // A fresh request has no tool turn to replay, so thinking stays at the
      // provider default (enabled).
      expect(seenBodies.at(-1)?.thinking).toBeUndefined();

      // The scheduler consumes the OpenAI-shaped view of every wire; the
      // tool-call id has to survive that translation too.
      const r2b = await fetch(`http://127.0.0.1:${KERNEL_PORT}/v1/chat/completions/stream`, {
        method: 'POST', headers: json,
        body: JSON.stringify({
          model: 'claude', provider: 'anth', messages: [{ role: 'user', content: 'hi' }],
          tools: [{ type: 'function', function: { name: 'read_file', description: 'read', parameters: { type: 'object' } } }],
        }),
      });
      const { frames: f2b } = await readSse(r2b);
      const anthIds = payloads(f2b).flatMap(p =>
        ((p.choices as { delta?: { tool_calls?: { id?: string }[] } }[] | undefined)?.[0]?.delta?.tool_calls) ?? [])
        .map(c => c.id);
      expect(anthIds).toContain('toolu_1');
      const anthReasoning = payloads(f2b)
        .map(p => ((p.choices as { delta?: { reasoning_content?: string; reasoning_signature?: string } }[] | undefined)?.[0]?.delta));
      expect(anthReasoning.map(d => d?.reasoning_content ?? '').join('')).toBe('weighing');
      expect(anthReasoning.map(d => d?.reasoning_signature ?? '').join('')).toBe('sig_stub');

      // A tool round must send the id back (anthropic: tool_use_id).
      const toolRound = [
        { role: 'user', content: 'hi' },
        { role: 'assistant', content: '', tool_calls: [{ id: 'call_x', type: 'function', function: { name: 'read_file', arguments: '{"path":"a.txt"}' } }] },
        { role: 'tool', tool_call_id: 'call_x', content: 'ok' },
      ];
      const r2c = await fetch(`http://127.0.0.1:${KERNEL_PORT}/v1/chat/completions/stream`, {
        method: 'POST', headers: json,
        body: JSON.stringify({ model: 'claude', provider: 'anth', messages: toolRound }),
      });
      await readSse(r2c);
      const anthBlocks = ((seenBodies.at(-1)?.messages as { content?: unknown }[] | undefined) ?? [])
        .flatMap(m => (Array.isArray(m.content) ? m.content : []) as { type?: string; tool_use_id?: string }[]);
      expect(anthBlocks.find(b => b.type === 'tool_result')?.tool_use_id).toBe('call_x');
      // A legacy tool turn has no signature to replay: disable thinking for
      // that request rather than sending an empty thinking block.
      expect((seenBodies.at(-1)?.thinking as { type?: string } | undefined)?.type).toBe('disabled');

      // A signed tool turn replays the thinking block and keeps thinking on.
      const signedRound = [
        { role: 'user', content: 'hi' },
        { role: 'assistant', content: '', reasoning_content: 'plan', reasoning_signature: 'sig_1',
          tool_calls: [{ id: 'call_x', type: 'function', function: { name: 'read_file', arguments: '{"path":"a.txt"}' } }] },
        { role: 'tool', tool_call_id: 'call_x', content: 'ok' },
      ];
      const r2d = await fetch(`http://127.0.0.1:${KERNEL_PORT}/v1/chat/completions/stream`, {
        method: 'POST', headers: json,
        body: JSON.stringify({ model: 'claude', provider: 'anth', messages: signedRound }),
      });
      await readSse(r2d);
      const signedBody = seenBodies.at(-1);
      expect(signedBody?.thinking).toBeUndefined();
      const signedBlocks = ((signedBody?.messages as { content?: unknown }[] | undefined) ?? [])
        .flatMap(m => (Array.isArray(m.content) ? m.content : []) as { type?: string; thinking?: string; signature?: string }[]);
      const think = signedBlocks.find(b => b.type === 'thinking');
      expect(think?.thinking).toBe('plan');
      expect(think?.signature).toBe('sig_1');

      // ── Responses wire: typed events, arguments reassembled ─────────
      await fetch(`http://127.0.0.1:${KERNEL_PORT}/providers`, {
        method: 'POST', headers: json,
        body: JSON.stringify({
          name: 'resp', kind: 'responses', baseUrl: `http://127.0.0.1:${STUB_PORT}`,
          apiKey: 'resp-key', models: ['gpt'], default: 'gpt',
        }),
      });
      const r3 = await fetch(`http://127.0.0.1:${KERNEL_PORT}/v1/responses/stream`, {
        method: 'POST', headers: json,
        body: JSON.stringify({ model: 'gpt', provider: 'resp', input: [{ role: 'user', content: 'hi' }] }),
      });
      expect(r3.headers.get('content-type')).toContain('text/event-stream');
      const { frames: f3, firstByteMs: t3 } = await readSse(r3);
      expect(responsesText(f3)).toBe('Hi from resp');
      expect(t3).toBeLessThan(STUB_GAP_MS);
      const respCall = payloads(f3, 'response.output_item.added')
        .map(p => (p.item as { type?: string; id?: string; name?: string; arguments?: string } | undefined))
        .find(i => i?.type === 'function_call');
      expect(respCall?.name).toBe('read_file');
      expect(respCall?.arguments).toBe('{"path":"a.txt"}');
      // The stub only gives an item id; it must not become an empty call_id.
      expect(respCall?.id).toBe('fc_1');
      expect(seenUrls.at(-1)).toBe('/v1/responses');
      expect(seenBodies.at(-1)?.stream).toBe(true);

      // A tool round must send a non-empty call_id (DeepSeek: 400 otherwise).
      const r3b = await fetch(`http://127.0.0.1:${KERNEL_PORT}/v1/chat/completions/stream`, {
        method: 'POST', headers: json,
        body: JSON.stringify({ model: 'gpt', provider: 'resp', messages: toolRound }),
      });
      await readSse(r3b);
      const respInput = (seenBodies.at(-1)?.input as { type?: string; call_id?: string }[] | undefined) ?? [];
      expect(respInput.find(i => i.type === 'function_call_output')?.call_id).toBe('call_x');
    } finally {
      kernel.kill('SIGTERM');
      await new Promise<void>(resolve => stub.close(() => resolve()));
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  }, 300_000);
});
