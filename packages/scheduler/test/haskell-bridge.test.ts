// Phase 3 K4: HaskellBridge talks to the kernel's OpenAI-compatible
// /v1/chat/completions endpoint (normalizes messages, parses tool_calls).

import express from 'express';
import { describe, it, expect } from 'vitest';
import type { Server } from 'http';
import type { AddressInfo } from 'net';
import { HaskellBridge } from '../src/Bridge/Haskell.js';

async function listen(app: express.Express): Promise<{ port: number; server: Server }> {
  const server = await new Promise<Server>((resolve) => {
    const s = app.listen(0, '127.0.0.1', () => resolve(s));
  });
  const { port } = server.address() as AddressInfo;
  return { port, server };
}

describe('HaskellBridge (Phase 3 K4)', () => {
  it('posts to /v1/chat/completions with normalized messages and parses tool_calls', async () => {
    const app = express();
    app.use(express.json());
    let receivedBody: unknown = null;
    app.post('/v1/chat/completions', (req, res) => {
      receivedBody = req.body;
      res.json({
        id: 'chatcmpl-1',
        object: 'chat.completion',
        model: 'deepseek-chat',
        choices: [{
          index: 0,
          message: {
            role: 'assistant',
            content: '',
            tool_calls: [
              { id: 'call_1', type: 'function', function: { name: 'bash', arguments: '{"command":"ls"}' } },
            ],
          },
          finish_reason: 'tool_calls',
        }],
        usage: { prompt_tokens: 3, completion_tokens: 5, total_tokens: 8 },
      });
    });
    const { port, server } = await listen(app);

    const bridge = new HaskellBridge({ host: '127.0.0.1', port });
    const res = await bridge.queryModel({
      messages: [['user', 'list files'], { role: 'assistant', content: '', tool_calls: [{ id: 'x', type: 'function', function: { name: 'y', arguments: '{}' } }] }],
      tools: [{ name: 'bash', description: 'Run a command', parameters: { type: 'object' } }],
      model: 'deepseek-chat',
    });

    expect(res.reply).toBe('');
    expect(res.toolCalls).toEqual([{ id: 'call_1', name: 'bash', arguments: '{"command":"ls"}' }]);
    expect(res.usage?.totalTokens).toBe(8);

    const body = receivedBody as { messages: unknown[]; tools?: unknown[]; model?: string; stream: boolean };
    expect(body.messages[0]).toEqual({ role: 'user', content: 'list files' });
    expect(body.messages[1]).toHaveProperty('tool_calls');
    expect(body.tools).toHaveLength(1);
    expect((body.tools![0] as { type: string }).type).toBe('function');
    expect(body.model).toBe('deepseek-chat');
    expect(body.stream).toBe(false);

    server.close();
  });

  it('parses a plain textual completion', async () => {
    const app = express();
    app.use(express.json());
    app.post('/v1/chat/completions', (_req, res) => {
      res.json({
        choices: [{ message: { role: 'assistant', content: 'hello world' }, finish_reason: 'stop' }],
      });
    });
    const { port, server } = await listen(app);

    const bridge = new HaskellBridge({ host: '127.0.0.1', port });
    const res = await bridge.queryModel({ messages: [['user', 'hi']] });
    expect(res.reply).toBe('hello world');
    expect(res.toolCalls).toBeUndefined();

    server.close();
  });

  it('derives totalTokens when the wire omits it', async () => {
    const app = express();
    app.use(express.json());
    app.post('/v1/chat/completions', (_req, res) => {
      res.json({
        choices: [{ message: { role: 'assistant', content: 'ok' }, finish_reason: 'stop' }],
        usage: { prompt_tokens: 10, completion_tokens: 5 },
      });
    });
    const { port, server } = await listen(app);

    const bridge = new HaskellBridge({ host: '127.0.0.1', port });
    const res = await bridge.queryModel({ messages: [['user', 'hi']] });

    // A turn's total is prompt + completion, not an undefined that the shell
    // would then fill from a session lifetime counter.
    expect(res.usage?.promptTokens).toBe(10);
    expect(res.usage?.completionTokens).toBe(5);
    expect(res.usage?.totalTokens).toBe(15);

    server.close();
  });

  it('merges streamed usage frames instead of erasing earlier fields', async () => {
    const app = express();
    app.use(express.json());
    app.post('/v1/chat/completions/stream', (_req, res) => {
      res.writeHead(200, { 'Content-Type': 'text/event-stream' });
      res.write(`data: ${JSON.stringify({ usage: { prompt_tokens: 12, prompt_cache_hit_tokens: 9 } })}\n\n`);
      // The second frame omits prompt/total/cache: a replace would write
      // undefined over the numbers the first frame already reported.
      res.write(`data: ${JSON.stringify({ usage: { completion_tokens: 3 } })}\n\n`);
      res.write('data: [DONE]\n\n');
      res.end();
    });
    const { port, server } = await listen(app);

    const bridge = new HaskellBridge({ host: '127.0.0.1', port });
    const res = await bridge.queryModelStream({ messages: [['user', 'hi']] }, () => {});

    expect(res.usage?.promptTokens).toBe(12);
    expect(res.usage?.cacheHitTokens).toBe(9);
    expect(res.usage?.completionTokens).toBe(3);
    expect(res.usage?.totalTokens).toBe(15);

    server.close();
  });
});
