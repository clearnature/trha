// Phase 3 K5: the orchestration agent step loops tools against a stub
// kernel: round 1 returns a read_file tool call, the host executes it
// (real fs read), the result is fed back, round 2 returns plain text.

import express from 'express';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { describe, it, expect } from 'vitest';
import type { Server } from 'http';
import type { AddressInfo } from 'net';
import { createServer } from '../src/Server/index.js';

async function listen(app: express.Express): Promise<{ port: number; server: Server }> {
  const server = await new Promise<Server>((resolve) => {
    const s = app.listen(0, '127.0.0.1', () => resolve(s));
  });
  const { port } = server.address() as AddressInfo;
  return { port, server };
}

const auth = { 'Content-Type': 'application/json', Authorization: 'Bearer dev-token' } as Record<string, string>;

describe('agent tool loop (Phase 3 K5)', () => {
  it('executes a read_file tool call and feeds the result back to the model', async () => {
    const dir = await mkdtemp(path.join(tmpdir(), 'trha-k5-'));
    const file = path.join(dir, 'notes.txt');
    await writeFile(file, 'hello-from-file', 'utf8');

    // Stub kernel: call 1 -> tool_calls; call 2 -> plain text echoing the
    // content of the last tool message it received.
    let calls = 0;
    let sawToolResult = false;
    const kernel = express();
    kernel.use(express.json());
    kernel.post('/v1/chat/completions', (req, res) => {
      calls++;
      if (calls === 1) {
        res.json({
          choices: [{
            message: {
              role: 'assistant', content: '',
              tool_calls: [{ id: 'call_r', type: 'function', function: { name: 'read_file', arguments: JSON.stringify({ path: file }) } }],
            },
            finish_reason: 'tool_calls',
          }],
        });
      } else {
        const msgs = req.body.messages as Array<{ role: string; content: string; tool_call_id?: string }>;
        const lastTool = [...msgs].reverse().find(m => m.role === 'tool');
        if (lastTool && lastTool.content.includes('hello-from-file')) sawToolResult = true;
        res.json({
          choices: [{ message: { role: 'assistant', content: `file says: ${lastTool?.content ?? '?'}`, finish_reason: 'stop' } }],
        });
      }
    });
    const kernelServer = await listen(kernel);

    const { app } = createServer({
      port: 0, token: 'dev-token',
      haskellHost: '127.0.0.1', haskellPort: kernelServer.port,
    });
    const schedulerServer = await listen(app);
    const base = schedulerServer.port === 0 ? '' : `http://127.0.0.1:${schedulerServer.port}`;

    const start = await fetch(`${base}/api/session/start`, { method: 'POST', headers: auth, body: JSON.stringify({ mode: 'standard' }) });
    const { sessionId } = (await start.json()) as { sessionId: string };

    const step = await fetch(`${base}/api/agent/step`, { method: 'POST', headers: auth, body: JSON.stringify({ sessionId, message: 'read the file' }) });
    const stepJson = (await step.json()) as { reply?: string; messages?: Array<{ role: string }> };
    expect(stepJson.reply).toContain('file says: hello-from-file');
    expect(sawToolResult).toBe(true);

    const roles = (stepJson.messages ?? []).map(m => m.role);
    expect(roles).toContain('tool');
    expect(roles).toContain('assistant');

    kernelServer.server.close();
    schedulerServer.server.close();
    await rm(dir, { recursive: true, force: true });
  });
});
