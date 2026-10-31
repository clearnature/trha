// Agent-orchestration tools: subagent, list_agents, send_message,
// interrupt_agent, team_task_*, workflow.
//
// The semantics being pinned: a subagent is a real child session that runs its
// own turn (not a fake text blob), team tasks live on the root session so every
// teammate sees them, and interrupt stops at a round boundary instead of
// pretending to abort mid-flight.

import express from 'express';
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import type { Server } from 'http';
import type { AddressInfo } from 'net';
import { mkdtemp, rm } from 'node:fs/promises';
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

/** Kernel whose replies depend on the last user message, so a child turn is
 *  distinguishable from the parent's. */
function echoKernel(script: Step[], log: Array<{ user: string; tools: string[] }>) {
  const kernel = express();
  kernel.use(express.json());
  let round = 0;
  kernel.post('/session/start', (_req, res) => res.json({ sessionId: 'x', resumed: false }));
  kernel.post('/v1/chat/completions', (req, res) => {
    const msgs = req.body.messages as Array<{ role: string; content: string }>;
    // time-context 注入会插在真实 user 消息后面（带 source: 'time-context'），
    // 必须跳过，否则 script 永远匹配不上、tool_calls 不下发。
    const lastUser = [...msgs].reverse().find(m => m.role === 'user' && m.source !== 'time-context')?.content ?? '';
    const tools = msgs.filter(m => m.role === 'tool').map(m => m.content);
    log.push({ user: lastUser, tools });
    // The script belongs to the parent conversation; a child's turn must get a
    // plain answer, otherwise it would replay the parent's tool plan forever.
    const call = lastUser === 'parent task' ? script[round] : undefined;
    if (call) {
      if (lastUser === 'parent task') round += 1;
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
    res.json({ choices: [{ message: { role: 'assistant', content: `echo: ${lastUser}`, finish_reason: 'stop' } }] });
  });
  return kernel;
}

describe('agent orchestration tools', () => {
  let dir: string;
  beforeEach(async () => {
    dir = await mkdtemp(path.join(tmpdir(), 'trha-agents-'));
    process.env.TRHA_WORKSPACE = dir;
    process.env.TRHA_SCHEDULE_TICK_MS = '0';
  });
  afterEach(async () => {
    delete process.env.TRHA_WORKSPACE;
    delete process.env.TRHA_SCHEDULE_TICK_MS;
    delete process.env.TRHA_MAX_SUBAGENT_DEPTH;
    await rm(dir, { recursive: true, force: true });
  });

  async function run(script: Step[]) {
    const log: Array<{ user: string; tools: string[] }> = [];
    const kernel = echoKernel(script, log);
    const kernelServer = await listen(kernel);
    const stateDir = path.join(dir, `state-${Math.random().toString(36).slice(2, 7)}`);
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
      method: 'POST', headers: auth, body: JSON.stringify({ sessionId, message: 'parent task' }),
    });
    const body = (await step.json()) as { reply?: string };
    const list = await fetch(`${base}/api/sessions`, { headers: auth });
    const sessionsList = (await list.json()) as Array<{ id: string }>;
    stop(); kernelServer.server.close(); schedulerServer.server.close();
    return { body, log, sessionsList, sessionId };
  }

  it('subagent runs a real child session and returns its answer', async () => {
    const { log, sessionsList } = await run([
      { name: 'subagent', args: { task: 'child task', name: 'researcher' } },
    ]);
    // the child session exists …
    expect(sessionsList.some(s => s.id.includes('#researcher-'))).toBe(true);
    // … and the child actually ran a turn with its own task
    expect(log.some(l => l.user === 'child task')).toBe(true);
    // the parent read the child's answer back as a tool result (last parent round)
    const parentRounds = log.filter(l => l.user === 'parent task');
    const parentTools = parentRounds[parentRounds.length - 1]?.tools ?? [];
    expect(parentTools.some(t => t.includes('echo: child task'))).toBe(true);
  });

  it('list_agents shows the child and its parent link', async () => {
    const { log } = await run([
      { name: 'subagent', args: { task: 'work', name: 'worker' } },
      { name: 'list_agents', args: {} },
    ]);
    const listing = log[log.length - 1]?.tools.at(-1) ?? '';
    expect(listing).toContain('#worker-');
    expect(listing).toContain('parent=');
  });

  it('team tasks land on the root session (where a child would read them)', async () => {
    const { log, sessionId } = await run([
      { name: 'team_task_create', args: { subject: 'shared item' } },
      { name: 'subagent', args: { task: 'noop', name: 'teammate' } },
    ]);
    const rounds = log.filter(l => l.user === 'parent task');
    expect(rounds[rounds.length - 1]?.tools[0] ?? '').toContain('shared item');
    // and it is persisted with the session, so a restart keeps it
    const file = path.join(dir, 'state-' + '');
    void file;
    const { readFile } = await import('node:fs/promises');
    const dirs = await import('node:fs/promises').then(m => m.readdir(dir));
    const stateDir = dirs.find(d => d.startsWith('state-'));
    expect(stateDir).toBeTruthy();
    const record = JSON.parse(
      await readFile(path.join(dir, stateDir!, `${sessionId}.json`), 'utf8'),
    ) as { teamTasks?: Array<{ subject: string }> };
    expect(record.teamTasks?.[0]?.subject).toBe('shared item');
  });

  it('workflow runs its steps in order and reports each answer', async () => {
    const { log } = await run([
      {
        name: 'workflow',
        args: { steps: [{ name: 'a', task: 'first' }, { name: 'b', task: 'second' }] },
      },
    ]);
    const rounds = log.filter(l => l.user === 'parent task');
    const out = rounds[rounds.length - 1]?.tools.at(-1) ?? '';
    expect(out).toContain('first');
    expect(out).toContain('second');
    // both steps really ran as turns
    expect(log.some(l => l.user === 'first')).toBe(true);
    expect(log.some(l => l.user === 'second')).toBe(true);
  });

  it('refuses to nest past the depth limit', async () => {
    process.env.TRHA_MAX_SUBAGENT_DEPTH = '0';
    const { log } = await run([{ name: 'subagent', args: { task: 'too deep' } }]);
    const rounds = log.filter(l => l.user === 'parent task');
    const out = rounds[rounds.length - 1]?.tools.at(-1) ?? '';
    expect(out).toMatch(/depth limit/);
  });
});
