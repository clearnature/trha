// The system prompt: the mode persona was config-only before (nothing read it),
// so the model never received a system message at all. These tests pin that it
// is sent, that it is *computed per request* (not stored in the transcript), and
// that the todo discipline — one write per phase — is part of it.

import express from 'express';
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import type { Server } from 'http';
import type { AddressInfo } from 'node:net';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { createServer } from '../src/Server/index.js';

const auth = { 'Content-Type': 'application/json', Authorization: 'Bearer dev-token' } as Record<string, string>;

async function listen(app: express.Express): Promise<{ port: number; server: Server }> {
  const s = await new Promise<Server>(resolve => {
    const srv = app.listen(0, '127.0.0.1', () => resolve(srv));
  });
  return { port: (s.address() as AddressInfo).port, server: s };
}

/** Kernel that records the messages it was asked to complete. */
function recordingKernel(seen: Array<{ role: string; content: string }[]>) {
  const kernel = express();
  kernel.use(express.json());
  kernel.post('/session/start', (_q, res) => res.json({}));
  kernel.post('/v1/chat/completions', (req, res) => {
    seen.push(req.body.messages as Array<{ role: string; content: string }>);
    res.json({ choices: [{ message: { role: 'assistant', content: 'ok', finish_reason: 'stop' } }] });
  });
  return kernel;
}

describe('system prompt', () => {
  let dir: string;
  beforeEach(async () => { dir = await mkdtemp(path.join(tmpdir(), 'trha-sys-')); });
  afterEach(async () => { await rm(dir, { recursive: true, force: true }); });

  async function run(mode: string): Promise<{ seen: Array<{ role: string; content: string }[]>; stateDir: string; sessionId: string }> {
    const seen: Array<{ role: string; content: string }[]> = [];
    const kernel = recordingKernel(seen);
    const kernelServer = await listen(kernel);
    const stateDir = path.join(dir, `state-${mode}`);
    const { app, stop } = createServer({
      port: 0, token: 'dev-token', haskellHost: '127.0.0.1', haskellPort: kernelServer.port, stateDir,
    });
    const schedulerServer = await listen(app);
    const base = `http://127.0.0.1:${schedulerServer.port}`;
    const start = await fetch(`${base}/api/session/start`, {
      method: 'POST', headers: auth, body: JSON.stringify({ mode }),
    });
    const { sessionId } = (await start.json()) as { sessionId: string };
    await fetch(`${base}/api/agent/step`, {
      method: 'POST', headers: auth, body: JSON.stringify({ sessionId, message: 'hello' }),
    });
    stop(); kernelServer.server.close(); schedulerServer.server.close();
    return { seen, stateDir, sessionId };
  }

  it('sends the mode persona first, with the todo discipline', async () => {
    const { seen } = await run('standard');
    const first = seen[0]!;
    expect(first[0]?.role).toBe('system');
    expect(first[0]?.content).toContain('coding agent');
    // the cwd is rendered, not left as a template
    expect(first[0]?.content).toContain('working directory is');
    expect(first[0]?.content).not.toContain('{{cwd}}');
    // the rule that stops the todo_write loop
    expect(first[0]?.content).toContain('todo_write');
    expect(first[0]?.content).toMatch(/at most once/i);
    // and the user message still follows it
    expect(first[1]).toMatchObject({ role: 'user', content: 'hello' });
  });

  it('does not store the system message in the transcript', async () => {
    const { stateDir, sessionId } = await run('standard');
    const record = JSON.parse(
      await readFile(path.join(stateDir, `${sessionId}.json`), 'utf8'),
    ) as { messages: Array<{ role: string }> };
    // computed per request: the shell's transcript stays free of it
    expect(record.messages.some(m => m.role === 'system')).toBe(false);
  });

  it('sends no system message for a mode with the persona disabled', async () => {
    const { seen } = await run('minimal');
    expect(seen[0]?.[0]?.role).toBe('user');
  });
});
