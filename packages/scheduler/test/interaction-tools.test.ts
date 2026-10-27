// Interaction tools: the ones where the turn must stop and wait for a human,
// plus the two that just need a local runtime.
//
// The rule being tested throughout: a tool that needs input ends the turn and
// parks state on the session — it must never fabricate the answer.

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
  const s = await new Promise<Server>(resolve => {
    const srv = app.listen(0, '127.0.0.1', () => resolve(srv));
  });
  return { port: (s.address() as AddressInfo).port, server: s };
}

interface Step { name: string; args: Record<string, unknown> }

function scriptedKernel(script: Step[], sink: string[]) {
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
            tool_calls: [{ id: `call_${round}`, type: 'function', function: { name: call.name, arguments: JSON.stringify(call.args) } }],
          },
          finish_reason: 'tool_calls',
        }],
      });
    }
    sink.push(...results);
    res.json({ choices: [{ message: { role: 'assistant', content: 'done', finish_reason: 'stop' } }] });
  });
  return kernel;
}

describe('interaction tools', () => {
  let dir: string;
  beforeEach(async () => {
    dir = await mkdtemp(path.join(tmpdir(), 'trha-int-'));
    process.env.TRHA_WORKSPACE = dir;
    process.env.TRHA_SCHEDULE_TICK_MS = '0';
  });
  afterEach(async () => {
    delete process.env.TRHA_WORKSPACE;
    delete process.env.TRHA_SCHEDULE_TICK_MS;
    await rm(dir, { recursive: true, force: true });
  });

  it('ask_user_question parks the question, ends the turn, and the answer resumes', async () => {
    const results: string[] = [];
    const script: Step[] = [{ name: 'ask_user_question', args: { question: 'which branch?', options: ['main', 'dev'] } }];
    const kernel = scriptedKernel(script, results);
    const kernelServer = await listen(kernel);
    const stateDir = path.join(dir, 'state');
    const { app, stop } = createServer({
      port: 0, token: 'dev-token', haskellHost: '127.0.0.1', haskellPort: kernelServer.port, stateDir,
    });
    const schedulerServer = await listen(app);
    const base = `http://127.0.0.1:${schedulerServer.port}`;

    const start = await fetch(`${base}/api/session/start`, {
      method: 'POST', headers: auth, body: JSON.stringify({ mode: 'standard', permissionMode: 'yolo' }),
    });
    const { sessionId } = (await start.json()) as { sessionId: string };

    const step = await fetch(`${base}/api/agent/step`, {
      method: 'POST', headers: auth, body: JSON.stringify({ sessionId, message: 'start' }),
    });
    const body = (await step.json()) as { reply?: string };
    // the turn ends with the question, not with a fabricated answer
    expect(body.reply).toContain('which branch?');

    const record = JSON.parse(await readFile(path.join(stateDir, `${sessionId}.json`), 'utf8')) as {
      pendingQuestion?: { question?: string } | null;
    };
    expect(record.pendingQuestion?.question).toBe('which branch?');

    // answering runs the next turn
    const answer = await fetch(`${base}/api/session/${sessionId}/answer`, {
      method: 'POST', headers: auth, body: JSON.stringify({ answer: 'dev' }),
    });
    expect(answer.status).toBe(200);
    const after = (await answer.json()) as { status?: string; reply?: string };
    expect(after.status).toBe('answered');

    const resolved = JSON.parse(await readFile(path.join(stateDir, `${sessionId}.json`), 'utf8')) as {
      pendingQuestion?: unknown;
    };
    expect(resolved.pendingQuestion).toBeNull();

    stop(); kernelServer.server.close(); schedulerServer.server.close();
  });

  it('exit_plan_mode turns into the approval gate instead of a second plan mechanism', async () => {
    const results: string[] = [];
    const script: Step[] = [{ name: 'exit_plan_mode', args: { plan: 'do the thing' } }];
    const kernel = scriptedKernel(script, results);
    const kernelServer = await listen(kernel);
    const stateDir = path.join(dir, 'state2');
    const { app, stop } = createServer({
      port: 0, token: 'dev-token', haskellHost: '127.0.0.1', haskellPort: kernelServer.port, stateDir,
    });
    const schedulerServer = await listen(app);
    const base = `http://127.0.0.1:${schedulerServer.port}`;

    const start = await fetch(`${base}/api/session/start`, {
      method: 'POST', headers: auth, body: JSON.stringify({ mode: 'standard', permissionMode: 'yolo' }),
    });
    const { sessionId } = (await start.json()) as { sessionId: string };
    const step = await fetch(`${base}/api/agent/step`, {
      method: 'POST', headers: auth, body: JSON.stringify({ sessionId, message: 'plan it' }),
    });
    expect(((await step.json()) as { reply?: string }).reply).toContain('do the thing');

    const record = JSON.parse(await readFile(path.join(stateDir, `${sessionId}.json`), 'utf8')) as {
      pendingApproval?: { message?: string } | null;
    };
    expect(record.pendingApproval?.message).toBe('do the thing');

    stop(); kernelServer.server.close(); schedulerServer.server.close();
  });

  it('run_code executes a snippet and returns its output', async () => {
    const results: string[] = [];
    const script: Step[] = [{
      name: 'run_code',
      args: { language: 'python', code: 'print(2 + 40)' },
    }];
    const kernel = scriptedKernel(script, results);
    const kernelServer = await listen(kernel);
    const stateDir = path.join(dir, 'state3');
    const { app, stop } = createServer({
      port: 0, token: 'dev-token', haskellHost: '127.0.0.1', haskellPort: kernelServer.port, stateDir,
    });
    const schedulerServer = await listen(app);
    const base = `http://127.0.0.1:${schedulerServer.port}`;

    const start = await fetch(`${base}/api/session/start`, {
      method: 'POST', headers: auth, body: JSON.stringify({ mode: 'standard', permissionMode: 'yolo' }),
    });
    const { sessionId } = (await start.json()) as { sessionId: string };
    await fetch(`${base}/api/agent/step`, {
      method: 'POST', headers: auth, body: JSON.stringify({ sessionId, message: 'compute' }),
    });

    // the tool result the model would read
    expect(results.some(r => r.includes('42'))).toBe(true);

    stop(); kernelServer.server.close(); schedulerServer.server.close();
  });

  it('read_image returns a data URL and refuses an oversized file', async () => {
    const small = path.join(dir, 'tiny.png');
    await writeFile(small, Buffer.from([0x89, 0x50, 0x4e, 0x47]));
    const results: string[] = [];
    const script: Step[] = [
      { name: 'read_image', args: { path: 'tiny.png' } },
      { name: 'read_image', args: { path: 'big.bin' } },
    ];
    await writeFile(path.join(dir, 'big.bin'), Buffer.alloc(3 * 1024 * 1024));
    const kernel = scriptedKernel(script, results);
    const kernelServer = await listen(kernel);
    const stateDir = path.join(dir, 'state4');
    const { app, stop } = createServer({
      port: 0, token: 'dev-token', haskellHost: '127.0.0.1', haskellPort: kernelServer.port, stateDir,
    });
    const schedulerServer = await listen(app);
    const base = `http://127.0.0.1:${schedulerServer.port}`;

    const start = await fetch(`${base}/api/session/start`, {
      method: 'POST', headers: auth, body: JSON.stringify({ mode: 'standard', permissionMode: 'yolo' }),
    });
    const { sessionId } = (await start.json()) as { sessionId: string };
    await fetch(`${base}/api/agent/step`, {
      method: 'POST', headers: auth, body: JSON.stringify({ sessionId, message: 'look' }),
    });

    expect(results[0]).toMatch(/^data:image\/png;base64,/);
    expect(results[1]).toMatch(/cap is 2 MiB/);

    stop(); kernelServer.server.close(); schedulerServer.server.close();
  });

  it('present records a card and keeps the turn going', async () => {
    const results: string[] = [];
    const script: Step[] = [
      { name: 'present', args: { title: 'Result', body: 'all green' } },
      { name: 'present', args: { title: 'Still going', body: 'more' } },
    ];
    const kernel = scriptedKernel(script, results);
    const kernelServer = await listen(kernel);
    const stateDir = path.join(dir, 'state5');
    const { app, stop } = createServer({
      port: 0, token: 'dev-token', haskellHost: '127.0.0.1', haskellPort: kernelServer.port, stateDir,
    });
    const schedulerServer = await listen(app);
    const base = `http://127.0.0.1:${schedulerServer.port}`;

    const start = await fetch(`${base}/api/session/start`, {
      method: 'POST', headers: auth, body: JSON.stringify({ mode: 'standard', permissionMode: 'yolo' }),
    });
    const { sessionId } = (await start.json()) as { sessionId: string };
    const step = await fetch(`${base}/api/agent/step`, {
      method: 'POST', headers: auth, body: JSON.stringify({ sessionId, message: 'show me' }),
    });
    expect(step.status).toBe(200);
    const record = JSON.parse(await readFile(path.join(stateDir, `${sessionId}.json`), 'utf8')) as {
      messages: Array<{ role: string; content: string }>;
      presentations?: Array<{ card: string }>;
    };
    // A card is UI state, not a fabricated assistant turn in the history.
    expect(record.presentations?.[0]?.card).toContain('all green');
    expect(record.messages.some(m => (m.content ?? '').startsWith('[presentation]'))).toBe(false);

    stop(); kernelServer.server.close(); schedulerServer.server.close();
  });
});
