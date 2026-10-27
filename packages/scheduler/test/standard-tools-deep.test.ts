// standardTools 深分支测试：状态机（todo/goal/schedule/job/skill）与各 handler
// 的分支变体。外部依赖全部 mock（browser/lsp 模块、全局 fetch）。
import { beforeEach, afterEach, describe, expect, it, vi } from 'vitest';
import { mkdtemp, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';

vi.mock('../src/Server/browser.js', () => ({
  browserNavigate: async () => ({ title: 'T', url: 'u', text: 'body' }),
  browserExtract: async () => 'extracted',
  browserScreenshot: async (_s: string, ws: string) => path.join(ws, 'shot.png'),
  browserClose: async () => undefined,
}));
vi.mock('../src/Server/lsp.js', () => ({
  lspQuery: async (a: { operation: string }) => `LSP-MOCK ${a.operation}`,
  shutdownLsp: () => undefined,
  lspStatus: () => ({ servers: [] }),
}));

import {
  STANDARD_TOOL_NAMES,
  runStandardTool,
  startJob,
  writeSkill,
  type StandardToolHost,
  type AgentHooks,
} from '../src/Server/standardTools.js';

let workspace = '';
let teamTasks: Array<Record<string, unknown>> = [];

const agents = (): AgentHooks => ({
  spawn: async (task: string) => ({ id: `ag-${task.length}`, reply: `did ${task}` }),
  list: () => [{ id: 'ag-1', busy: false, messages: 2, parentId: 'p1' }],
  send: async (to: string, _text: string) =>
    to === 'ag-1' ? { delivered: true, reply: 'got it' } : { delivered: false },
  interrupt: (id: string) => id === 'ag-1',
  teamTasks: () => teamTasks,
  setTeamTasks: (t: Array<Record<string, unknown>>) => { teamTasks = t; },
} as unknown as AgentHooks);

const host = (over: Partial<StandardToolHost> = {}): StandardToolHost => ({
  workspace,
  state: {},
  jobs: new Map(),
  sessionId: 'deep',
  ...over,
});

const run = (name: string, args: Record<string, unknown>, h: StandardToolHost): Promise<string | null> =>
  runStandardTool(name, args, h).catch((e: Error) => `THREW: ${e.message}`);

beforeEach(async () => {
  workspace = await mkdtemp(path.join(tmpdir(), 'std-deep-'));
  teamTasks = [];
  vi.stubGlobal('fetch', async () => ({
    ok: true,
    status: 200,
    headers: { get: () => 'text/html' },
    text: async () => '<html><body>page body</body></html>',
  }) as unknown as Response);
});

afterEach(() => {
  vi.unstubAllGlobals();
});

describe('standardTools 深分支（状态机 + handler 变体）', () => {
  it('todo_write：写入 / UNCHANGED 判同 / 非数组报错 / 非法状态归 pending', async () => {
    const h = host();
    expect(await run('todo_write', { todos: 'nope' }, h)).toContain('must be an array');
    expect(await run('todo_write', { todos: [{ text: 'a', status: 'pending' }, { content: 'b' }] }, h))
      .toContain('OK: 2 todos');
    expect(h.state.todos).toHaveLength(2);
    expect(h.state.todos?.[1].status).toBe('pending');   // 非法状态归 pending
    // 同集合乱序 → UNCHANGED（sameTodos 判同分支）
    const reordered = [...(h.state.todos ?? [])].reverse();
    expect(await run('todo_write', { todos: reordered }, h)).toContain('UNCHANGED');
  });

  it('goal：create / get / update（status 合法与非法）/ 未设时 update 报错', async () => {
    const h = host();
    expect(await run('update_goal', { status: 'complete' }, h)).toContain('no goal is set');
    expect(await run('create_goal', { objective: '  finish M2  ', budget: 3 }, h)).toContain('finish M2');
    expect(await run('get_goal', {}, h)).toContain('"status":"active"');
    expect(await run('update_goal', { status: 'bogus' }, h)).toContain('must be active|paused|complete');
    expect(await run('update_goal', { status: 'paused', objective: 'finish M3' }, h)).toContain('"paused"');
  });

  it('schedule：create（ISO/epoch/坏 at）/ list / update（改 prompt、坏 at）/ delete（存在与不存在）', async () => {
    const h = host();
    expect(await run('schedule_create', { prompt: '' }, h)).toContain('prompt is required');
    expect(await run('schedule_create', { prompt: 'x', at: 'not-a-date' }, h)).toContain('must be an ISO');
    await run('schedule_create', { prompt: 'tick', at: new Date('2030-01-01T00:00:00Z').toISOString() }, h);
    await run('schedule_create', { prompt: 'tock', at: 1900000000000, repeat_ms: undefined, repeatMs: 5_000 }, h);
    expect(await run('schedule_list', {}, h)).toContain('tick');
    expect(await run('schedule_update', { id: 'sch-1', prompt: 'tick2' }, h)).toContain('tick2');
    expect(await run('schedule_update', { id: 'sch-1', at: 'bad' }, h)).toContain('bad at');
    expect(await run('schedule_update', { id: 'nope' }, h)).toContain('no schedule nope');
    expect(await run('schedule_delete', { id: 'nope' }, h)).toContain('no schedule nope');
    expect(await run('schedule_delete', { id: 'sch-2' }, h)).toContain('deleted sch-2');
  });

  it('job：startJob 产 id、list/output/kill 全生命周期', async () => {
    const h = host();
    h.jobs.set('dead', { id: 'dead', command: 'x', status: 'exited', output: [] });
    expect(await run('job_list', {}, h)).toContain('dead');
    expect(await run('job_output', { id: 'dead' }, h)).toContain('status: exited');
    expect(await run('job_kill', { id: 'dead' }, h)).toContain('already exited');
    expect(await run('job_output', { id: 'nope' }, h)).toContain('no job nope');
    const id = startJob(h, 'echo job-echo-test');
    expect(id).toBeTruthy();
    let out = '';
    for (let i = 0; i < 120 && !out.includes('exited'); i++) {  // 轮询至收尾（全量跑时机器更忙）
      await new Promise(r => setTimeout(r, 50));
      out = String(await run('job_output', { id }, h));
    }
    expect(out).toContain('exited');
    expect(out).toContain('job-echo-test');
    expect(await run('job_kill', { id }, h)).toContain('already exited');
  });

  it('skill：writeSkill 后 list 与 read 都可见；未知 skill 报可读错误', async () => {
    const h = host();
    const { mkdir } = await import('node:fs/promises');
    const skillDir = path.join(workspace, '.agents', 'skills');
    await mkdir(skillDir, { recursive: true });
    await writeSkill(skillDir, 'demo-skill', '---\ndescription: 演示\n---\nbody text');
    const list = await run('skill', {}, h);
    expect(String(list)).toContain('demo-skill');
    const body = await run('skill', { name: 'demo-skill' }, h);
    expect(String(body)).toContain('body text');
    expect(await run('skill', { name: 'missing' }, h)).toContain('no skill "missing"');
  });

  it('web_fetch：http(s) 校验 / fetch 走全局（stub 返回 html → 去标签）', async () => {
    const h = host();
    expect(await run('web_fetch', { url: 'ftp://x' }, h)).toContain('must be http');
    const r = await run('web_fetch', { url: 'http://example.com/' }, h);
    expect(String(r)).toContain('HTTP 200');
    expect(String(r)).toContain('page body');        // stripHtml 去标签
  });

  it('read_image：mime 分支 + 超 2MiB 拒绝 + 缺路径', async () => {
    const h = host();
    expect(await run('read_image', {}, h)).toContain('path is required');
    const png = Buffer.from([0x89, 0x50, 0x4e, 0x47]);
    await writeFile(path.join(workspace, 'x.png'), png);
    expect(await run('read_image', { path: 'x.png' }, h)).toContain('data:image/png;base64');
    await writeFile(path.join(workspace, 'big.png'), Buffer.alloc(2 * 1024 * 1024 + 1));
    expect(await run('read_image', { path: 'big.png' }, h)).toContain('the cap is 2 MiB');
  });

  it('run_code：bash 真跑 / 未知语言 / 空 code / 缺 code', async () => {
    const h = host();
    expect(await run('run_code', { language: 'bash', code: 'echo rc-hello' }, h)).toContain('rc-hello');
    expect(await run('run_code', { language: 'cobol', code: 'x' }, h)).toContain('unsupported language');
    expect(await run('run_code', { language: 'python', code: '  ' }, h)).toContain('code is required');
  });

  it('agents 家族：spawn/list/send（送达与未送达）/interrupt（忙与闲）/team 三件/workflow', async () => {
    const h = host({ agents: agents() });
    expect(await run('subagent', { task: 'dig' }, h)).toContain('did dig');
    expect(await run('list_agents', {}, h)).toContain('ag-1');
    expect(await run('send_message', { to: 'ag-1', text: 'hi' }, h)).toContain('reply from ag-1');
    expect(await run('send_message', { to: 'ghost', text: 'hi' }, h)).toContain('no agent ghost');
    expect(await run('interrupt_agent', { id: 'ag-1' }, h)).toContain('interrupted ag-1');
    expect(await run('interrupt_agent', { id: 'idle-1' }, h)).toContain('was idle');
    expect(await run('team_task_create', { subject: 't' }, h)).toContain('"subject":"t"');
    expect(await run('team_task_update', { id: 't1', status: 'completed', assignee: 'me' }, h))
      .toContain('"status":"completed"');
    expect(await run('team_task_list', {}, h)).toContain('"assignee":"me"');
    expect(await run('team_task_update', { id: 'nope' }, h)).toContain('no team task nope');
    const wf = await run('workflow', { steps: [{ name: 'a', task: 'dig' }, { name: 'b' }] }, h);
    expect(String(wf)).toContain('did dig');
    expect(String(wf)).toContain('missing task');
    expect(await run('workflow', { steps: [] }, h)).toContain('non-empty array');
  });

  it('agents 缺席时：subagent / list_agents / send_message / interrupt / team / workflow 全部可读报错', async () => {
    const h = host();
    for (const name of ['subagent', 'list_agents', 'send_message', 'interrupt_agent',
      'team_task_create', 'team_task_list', 'team_task_update', 'workflow']) {
      expect(String(await run(name, {}, h))).toContain('not available in this host');
    }
  });

  it('ask_user_question / exit_plan_mode / present 的分支', async () => {
    const h = host();
    expect(await run('ask_user_question', {}, h)).toContain('question is required');
    expect(await run('ask_user_question', { question: 'go?', options: ['yes', 3, 'no'] }, h))
      .toContain('WAITING_FOR_INPUT: go?');
    expect(h.state.pendingQuestion?.options).toEqual(['yes', 'no']);
    expect(await run('exit_plan_mode', {}, h)).toContain('WAITING_FOR_APPROVAL: exit plan mode');
    expect(await run('present', {}, h)).toContain('title or body is required');
    expect(await run('present', { title: 'T', body: 'B' }, h)).toContain('PRESENT');
  });

  it('lsp 分发：file 缺失 / operation 白名单 / 合法 operation 走 mock', async () => {
    const h = host();
    expect(await run('lsp', { operation: 'hover' }, h)).toContain('file is required');
    expect(await run('lsp', { file: 'a.ts', operation: 'nope' }, h)).toContain('operation must be');
    expect(await run('lsp', { file: 'a.ts', operation: 'hover', line: 2, character: 3 }, h))
      .toContain('LSP-MOCK hover');
  });

  it('STANDARD_TOOL_NAMES 名单内的每个名字都被分发器认识（返回非 undefined）', async () => {
    const h = host({ agents: agents() });
    for (const name of STANDARD_TOOL_NAMES) {
      const r = await run(name, {}, h).catch((e: Error) => `THREW: ${e.message}`);
      expect(r === null || typeof r === 'string').toBe(true);
    }
  });
});
