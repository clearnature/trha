// Standard tools ported from dsh's `standard` preset. Each block goes through
// the real tool loop against a scripted kernel, so what is asserted is the
// result the model would actually read.

import express from 'express';
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import type { Server } from 'http';
import type { AddressInfo } from 'net';
import { mkdtemp, rm } from 'node:fs/promises';
import http from 'node:http';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { createServer } from '../src/Server/index.js';
import { writeSkill } from '../src/Server/standardTools.js';

const auth = { 'Content-Type': 'application/json', Authorization: 'Bearer dev-token' } as Record<string, string>;

async function listen(app: express.Express): Promise<{ port: number; server: Server }> {
  const s = await new Promise<Server>(resolve => {
    const srv = app.listen(0, '127.0.0.1', () => resolve(srv));
  });
  return { port: (s.address() as AddressInfo).port, server: s };
}

interface Step { name: string; args: Record<string, unknown> }

/** Scripted kernel: plays `script`, then answers with the tool results. */
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
            tool_calls: [{
              id: `call_${round}`, type: 'function',
              function: { name: call.name, arguments: JSON.stringify(call.args) },
            }],
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

async function runScript(
  script: Step[],
  opts: { workspace: string; stateDir?: string; sessionId?: string },
): Promise<{ results: string[]; sessionId: string }> {
  const results: string[] = [];
  const kernelServer = await listen(scriptedKernel(script, results));
  const { app } = createServer({
    port: 0, token: 'dev-token', haskellHost: '127.0.0.1', haskellPort: kernelServer.port,
    ...(opts.stateDir ? { stateDir: opts.stateDir } : {}),
  });
  const schedulerServer = await listen(app);
  const base = `http://127.0.0.1:${schedulerServer.port}`;
  let sessionId = opts.sessionId;
  if (!sessionId) {
    const start = await fetch(`${base}/api/session/start`, {
      method: 'POST', headers: auth, body: JSON.stringify({ mode: 'standard', permissionMode: 'yolo' }),
    });
    sessionId = ((await start.json()) as { sessionId: string }).sessionId;
  }
  await fetch(`${base}/api/agent/step`, {
    method: 'POST', headers: auth,
    body: JSON.stringify({ sessionId, message: 'go' }),
  });
  kernelServer.server.close();
  schedulerServer.server.close();
  return { results, sessionId };
}

describe('standard tools (dsh port)', () => {
  let dir: string;
  beforeEach(async () => {
    dir = await mkdtemp(path.join(tmpdir(), 'trha-std-'));
    process.env.TRHA_WORKSPACE = dir;
  });
  afterEach(async () => {
    delete process.env.TRHA_WORKSPACE;
    delete process.env.TRHA_SKILLS_DIR;
    await rm(dir, { recursive: true, force: true });
  });

  it('todo_write replaces the list and tracks statuses', async () => {
    const { results: r } = await runScript([
      { name: 'todo_write', args: { todos: [
        { text: 'read the spec', status: 'completed' },
        { text: 'write the code', status: 'in_progress' },
      ] } },
      { name: 'todo_write', args: { todos: [{ text: 'ship it', status: 'pending' }] } },
    ], { workspace: dir });
    expect(r[0]).toContain('2 todos');
    expect(r[0]).toContain('[x] read the spec');
    expect(r[0]).toContain('[~] write the code');
    // a second write replaces rather than appends
    expect(r[1]).toContain('1 todos');
    expect(r[1]).toContain('ship it');
  });

  it('goal create → get → update', async () => {
    const { results: r } = await runScript([
      { name: 'create_goal', args: { objective: 'port the tools', budget: 10 } },
      { name: 'get_goal', args: {} },
      { name: 'update_goal', args: { status: 'complete' } },
    ], { workspace: dir });
    expect(r[0]).toContain('port the tools');
    expect(r[1]).toContain('"status":"active"');
    expect(r[2]).toContain('"status":"complete"');
  });

  it('schedules can be created, listed, updated and deleted', async () => {
    const at = new Date(Date.now() + 60_000).toISOString();
    const { results: r } = await runScript([
      { name: 'schedule_create', args: { prompt: 'check the build', at } },
      { name: 'schedule_list', args: {} },
      { name: 'schedule_update', args: { id: 'sch-1', prompt: 'check the tests' } },
      { name: 'schedule_delete', args: { id: 'sch-1' } },
    ], { workspace: dir });
    expect(r[0]).toContain('"prompt":"check the build"');
    expect(r[1]).toContain('sch-1');
    expect(r[2]).toContain('check the tests');
    expect(r[3]).toContain('deleted sch-1');
  });

  it('a background job runs, reports output and can be killed', async () => {
    const { results: r } = await runScript([
      { name: 'bash', args: { command: 'sleep 0.2; echo bg-done', background: true } },
      { name: 'job_list', args: {} },
      { name: 'job_kill', args: { id: 'job-1' } },
    ], { workspace: dir });
    expect(r[0]).toMatch(/OK: started job-/);
    expect(r[1]).toMatch(/job-/);
    // killing an already exiting job is still a clean answer, not an error
    expect(r[2]).toMatch(/^OK:/);
  });

  it('skill lists and loads markdown files from the skills directory', async () => {
    const skills = path.join(dir, '.trha', 'skills');
    await writeSkill(skills, 'lean', '# Lean\nUse core tactics.');
    process.env.TRHA_SKILLS_DIR = skills;
    const { results: r } = await runScript([
      { name: 'skill', args: {} },
      { name: 'skill', args: { name: 'lean' } },
      { name: 'skill', args: { name: 'nope' } },
    ], { workspace: dir });
    expect(r[0]).toContain('lean');
    expect(r[1]).toContain('Use core tactics');
    expect(r[2]).toMatch(/^ERROR: no skill/);
  });

  it('web_fetch returns stripped text from a live server', async () => {
    const page = '<html><head><style>b{}</style></head><body><h1>Title</h1><script>x()</script><p>Hello&nbsp;world</p></body></html>';
    const srv = http.createServer((_req, res) => {
      res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
      res.end(page);
    });
    await new Promise<void>(r => srv.listen(0, '127.0.0.1', r));
    const port = (srv.address() as AddressInfo).port;
    const { results: r } = await runScript([
      { name: 'web_fetch', args: { url: `http://127.0.0.1:${port}/` } },
    ], { workspace: dir });
    srv.close();
    expect(r[0]).toContain('HTTP 200');
    expect(r[0]).toContain('Title');
    expect(r[0]).toContain('Hello world');
    expect(r[0]).not.toContain('<h1>');
    expect(r[0]).not.toContain('x()');       // script stripped
  });

  it('todos and goal survive a scheduler restart (v2 persistence)', async () => {
    const stateDir = path.join(dir, 'state');
    const first = await runScript([
      { name: 'todo_write', args: { todos: [{ text: 'persist me', status: 'pending' }] } },
      { name: 'create_goal', args: { objective: 'survive restart' } },
    ], { workspace: dir, stateDir });

    // second process, same state directory and same session id — what a host
    // does after a restart
    const { results: r } = await runScript([
      { name: 'todo_write', args: { todos: [{ text: 'next', status: 'pending' }] } },
      { name: 'get_goal', args: {} },
    ], { workspace: dir, stateDir, sessionId: first.sessionId });
    // The reply lists every tool result in the (restored) history, so the
    // fresh get_goal answer is last — and it proves the goal came off disk.
    expect(r[r.length - 1]).toContain('survive restart');
  });
});
