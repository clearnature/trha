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
});
