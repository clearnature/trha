// Filesystem tools ported from deepseek-harness: write → edit → read → grep →
// glob, driven through a real tool loop against a fake kernel.
//
// The point is the contract, not the happy path alone: edit must refuse an
// ambiguous match, read must honour a line range, glob/grep must find what was
// just written, and the results must come back as tool messages the model can
// read.

import express from 'express';
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import type { Server } from 'http';
import type { AddressInfo } from 'net';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { createServer } from '../src/Server/index.js';

const auth = { 'Content-Type': 'application/json', Authorization: 'Bearer dev-token' } as Record<string, string>;

async function listen(app: express.Express): Promise<{ port: number; server: Server }> {
  const server = await new Promise<Server>(resolve => {
    const s = app.listen(0, '127.0.0.1', () => resolve(s));
  });
  return { port: (server.address() as AddressInfo).port, server };
}

interface ToolCall { id: string; name: string; args: Record<string, unknown> }

/** Fake kernel that plays a scripted list of tool calls, then answers. */
function scriptedKernel(script: ToolCall[], final: (results: string[]) => string, sink: string[]) {
  const kernel = express();
  kernel.use(express.json());
  let round = 0;
  kernel.post('/session/start', (_req, res) => res.json({ sessionId: 'x', resumed: false }));
  kernel.post('/v1/chat/completions', (req, res) => {
    const msgs = req.body.messages as Array<{ role: string; content: string }>;
    const results = msgs.filter(m => m.role === 'tool').map(m => m.content);
    if (round < script.length) {
      const call = script[round++]!;
      return res.json({
        choices: [{
          message: {
            role: 'assistant', content: '',
            tool_calls: [{
              id: call.id, type: 'function',
              function: { name: call.name, arguments: JSON.stringify(call.args) },
            }],
          },
          finish_reason: 'tool_calls',
        }],
      });
    }
    sink.push(...results);
    res.json({ choices: [{ message: { role: 'assistant', content: final(results), finish_reason: 'stop' } }] });
  });
  return kernel;
}

describe('filesystem tools (ported from deepseek-harness)', () => {
  let dir: string;
  beforeEach(async () => {
    dir = await mkdtemp(path.join(tmpdir(), 'trha-tools-'));
    // writes are confined to the workspace; make the test dir the workspace
    process.env.TRHA_WORKSPACE = dir;
  });
  afterEach(async () => {
    delete process.env.TRHA_WORKSPACE;
    await rm(dir, { recursive: true, force: true });
  });

  it('writes, edits, reads a range, greps and globs', async () => {
    const file = path.join(dir, 'notes.txt');
    const results: string[] = [];
    const script: ToolCall[] = [
      // relative on purpose: it must land in the workspace, not the cwd
      { id: 'c1', name: 'write', args: { path: 'notes.txt', content: 'alpha\nbeta\ngamma\n' } },
      { id: 'c2', name: 'edit', args: { path: 'notes.txt', old_string: 'beta', new_string: 'BETA' } },
      { id: 'c3', name: 'read', args: { path: 'notes.txt', offset: 2, limit: 1 } },
      { id: 'c4', name: 'grep', args: { pattern: 'BETA', path: dir } },
      { id: 'c5', name: 'glob', args: { pattern: '*.txt', path: dir } },
    ];
    const kernel = scriptedKernel(script, r => `done: ${r[r.length - 1] ?? ''}`, results);
    const kernelServer = await listen(kernel);
    const { app } = createServer({
      port: 0, token: 'dev-token', haskellHost: '127.0.0.1', haskellPort: kernelServer.port,
    });
    const schedulerServer = await listen(app);
    const base = `http://127.0.0.1:${schedulerServer.port}`;

    const start = await fetch(`${base}/api/session/start`, {
      method: 'POST', headers: auth, body: JSON.stringify({ mode: 'standard', permissionMode: 'yolo' }),
    });
    const { sessionId } = (await start.json()) as { sessionId: string };
    const step = await fetch(`${base}/api/agent/step`, {
      method: 'POST', headers: auth,
      body: JSON.stringify({ sessionId, message: 'use the tools' }),
    });
    expect(step.status).toBe(200);

    // the file on disk really changed
    expect(await readFile(file, 'utf8')).toBe('alpha\nBETA\ngamma\n');

    // the edit result carries a unified diff, so the TUI can render a patch card
    expect(results[1]).toContain('@@ -2,1 +2,1 @@');
    expect(results[1]).toContain('-beta');
    expect(results[1]).toContain('+BETA');

    // read(offset=2, limit=1) returned exactly line 2, numbered
    expect(results[2]).toContain('2\tBETA');
    expect(results[2]).not.toContain('alpha');
    // grep found the edited line, with path:line:text
    expect(results[3]).toContain('notes.txt:2:BETA');
    // glob matched the file we wrote
    expect(results[4]).toContain('notes.txt');

    kernelServer.server.close();
    schedulerServer.server.close();
  });

  it('refuses an ambiguous edit and leaves the file untouched', async () => {
    const file = path.join(dir, 'dup.txt');
    await writeFile(file, 'x\nx\n', 'utf8');
    const results: string[] = [];
    const script: ToolCall[] = [
      { id: 'c1', name: 'edit', args: { path: file, old_string: 'x', new_string: 'y' } },
    ];
    const kernel = scriptedKernel(script, r => `saw: ${r[0] ?? ''}`, results);
    const kernelServer = await listen(kernel);
    const { app } = createServer({
      port: 0, token: 'dev-token', haskellHost: '127.0.0.1', haskellPort: kernelServer.port,
    });
    const schedulerServer = await listen(app);
    const base = `http://127.0.0.1:${schedulerServer.port}`;

    const start = await fetch(`${base}/api/session/start`, {
      method: 'POST', headers: auth, body: JSON.stringify({ mode: 'standard', permissionMode: 'yolo' }),
    });
    const { sessionId } = (await start.json()) as { sessionId: string };
    await fetch(`${base}/api/agent/step`, {
      method: 'POST', headers: auth,
      body: JSON.stringify({ sessionId, message: 'edit it' }),
    });

    expect(results[0]).toMatch(/matches 2 times/);
    expect(await readFile(file, 'utf8')).toBe('x\nx\n');

    kernelServer.server.close();
    schedulerServer.server.close();
  });

  it('stops the loop when the same tool call repeats instead of running forever', async () => {
    const results: string[] = [];
    // identical call every round: the loop must break on repetition, not spin
    const repeat: ToolCall = { id: 'c1', name: 'glob', args: { pattern: '*.nothing', path: dir } };
    const kernel = scriptedKernel([repeat, repeat, repeat, repeat, repeat], () => 'unreachable', results);
    const kernelServer = await listen(kernel);
    const { app } = createServer({
      port: 0, token: 'dev-token', haskellHost: '127.0.0.1', haskellPort: kernelServer.port,
    });
    const schedulerServer = await listen(app);
    const base = `http://127.0.0.1:${schedulerServer.port}`;

    const start = await fetch(`${base}/api/session/start`, {
      method: 'POST', headers: auth, body: JSON.stringify({ mode: 'standard', permissionMode: 'yolo' }),
    });
    const { sessionId } = (await start.json()) as { sessionId: string };
    const step = await fetch(`${base}/api/agent/step`, {
      method: 'POST', headers: auth,
      body: JSON.stringify({ sessionId, message: 'loop please' }),
    });
    const body = (await step.json()) as { reply?: string };
    expect(body.reply).toMatch(/same tool call repeated/);

    kernelServer.server.close();
    schedulerServer.server.close();
  });
});
