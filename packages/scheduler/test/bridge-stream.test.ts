// A3.2: the scheduler's bridge must consume the kernel's SSE incrementally,
// so the UI can render the answer as it is produced.

import { describe, it, expect, afterEach } from 'vitest';
import { createServer } from 'node:http';
import type { Server, ServerResponse } from 'node:http';
import { HaskellBridge } from '../src/Bridge/Haskell.js';

let stub: Server | null = null;

afterEach(async () => {
  if (stub) {
    const s = stub;
    stub = null;
    await new Promise<void>(r => s.close(() => r()));
  }
});

async function runStub(
  handler: (url: string | undefined, body: unknown, res: ServerResponse) => void,
): Promise<number> {
  stub = createServer((req, res) => {
    let raw = '';
    req.on('data', c => { raw += c; });
    req.on('end', () => handler(req.url, JSON.parse(raw || '{}'), res));
  });
  await new Promise<void>(r => stub!.listen(0, '127.0.0.1', () => r()));
  const addr = stub.address();
  return typeof addr === 'object' && addr ? addr.port : 0;
}

describe('HaskellBridge.queryModelStream (A3)', () => {
  it('hands each increment to onDelta and returns their concatenation', async () => {
    const seenBodies: Record<string, unknown>[] = [];
    const port = await runStub((url, body, res) => {
      seenBodies.push(body as Record<string, unknown>);
      expect(url).toBe('/v1/chat/completions/stream');
      res.writeHead(200, { 'Content-Type': 'text/event-stream' });
      res.write(`data: ${JSON.stringify({ choices: [{ delta: { content: 'He' } }] })}\n\n`);
      res.write(`data: ${JSON.stringify({ choices: [{ delta: { content: 'llo' } }] })}\n\n`);
      // A tool call split across two frames.
      res.write(`data: ${JSON.stringify({ choices: [{ delta: { tool_calls: [{ index: 0, id: 'call_1', function: { name: 'read_file', arguments: '{"path":' } }] } }] })}\n\n`);
      res.write(`data: ${JSON.stringify({ choices: [{ delta: { tool_calls: [{ index: 0, function: { arguments: '"a.txt"}' } }] } }] })}\n\n`);
      res.write('data: [DONE]\n\n');
      res.end();
    });

    const seen: string[] = [];
    const bridge = new HaskellBridge({ host: '127.0.0.1', port });
    const out = await bridge.queryModelStream(
      { messages: [['user', 'hi']], model: 'm', provider: 'gw' },
      t => seen.push(t),
    );

    // Increments arrived one by one, in order.
    expect(seen).toEqual(['He', 'llo']);
    // …and the aggregate matches what the blocking call would have returned.
    expect(out.reply).toBe('Hello');
    expect(out.toolCalls?.[0]).toEqual({ id: 'call_1', name: 'read_file', arguments: '{"path":"a.txt"}' });
    // It asked the kernel to stream, with the chosen provider and model.
    expect(seenBodies[0].stream).toBe(true);
    expect(seenBodies[0].provider).toBe('gw');
    expect(seenBodies[0].model).toBe('m');
  });

  it('throws instead of silently returning an empty reply', async () => {
    const port = await runStub((_url, _body, res) => {
      res.writeHead(502, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ code: 'provider.kernel_unreachable' }));
    });
    const bridge = new HaskellBridge({ host: '127.0.0.1', port });
    await expect(bridge.queryModelStream({ messages: [['user', 'hi']] }, () => {}))
      .rejects.toThrow(/HTTP 502/);
  });

  it('streams reasoning deltas to the second sink', async () => {
    const port = await runStub((_url, _body, res) => {
      res.writeHead(200, { 'Content-Type': 'text/event-stream' });
      res.write(`data: ${JSON.stringify({ choices: [{ delta: { reasoning_content: 'thin' } }] })}\n\n`);
      res.write(`data: ${JSON.stringify({ choices: [{ delta: { reasoning_content: 'king' } }] })}\n\n`);
      res.write(`data: ${JSON.stringify({ choices: [{ delta: { content: 'answer' } }] })}\n\n`);
      res.write('data: [DONE]\n\n');
      res.end();
    });

    const text: string[] = [];
    const reasoning: string[] = [];
    const bridge = new HaskellBridge({ host: '127.0.0.1', port });
    const out = await bridge.queryModelStream(
      { messages: [['user', 'hi']] },
      t => text.push(t),
      t => reasoning.push(t),
    );

    expect(reasoning).toEqual(['thin', 'king']);
    expect(text).toEqual(['answer']);
    expect(out.reasoningContent).toBe('thinking');
    expect(out.reply).toBe('answer');
  });
});
