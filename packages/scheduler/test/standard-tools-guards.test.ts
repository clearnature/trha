// Error and edge branches for the standard tools.
//
// These are the paths a model actually hits when it calls a tool wrongly: the
// point is that the answer is a readable `ERROR: ...` string (a tool result it
// can recover from), never a thrown exception that kills the turn.

import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { isStandardTool, runStandardTool, startJob, STANDARD_TOOL_NAMES, writeSkill, type StandardToolHost } from '../src/Server/standardTools.js';

describe('standard tool guards', () => {
  let dir: string;
  let host: StandardToolHost;

  beforeEach(async () => {
    dir = await mkdtemp(path.join(tmpdir(), 'trha-guard-'));
    let teamTasks: import('../src/Server/standardTools.js').TeamTask[] = [];
    host = {
      workspace: dir, state: {}, jobs: new Map(), sessionId: 's',
      agents: {
        spawn: async () => ({ id: 's#sub-1', reply: 'ok' }),
        list: () => [{ id: 's', messages: 0 }, { id: 's#sub-1', parentId: 's', messages: 1 }],
        send: async () => ({ delivered: true, reply: 'ok' }),
        interrupt: () => false,
        teamTasks: () => teamTasks,
        setTeamTasks: tasks => { teamTasks = tasks; },
      },
    };
  });
  afterEach(async () => { await rm(dir, { recursive: true, force: true }); });

  const run = (name: string, args: Record<string, unknown> = {}) => runStandardTool(name, args, host);

  it('knows exactly the declared names', async () => {
    for (const n of STANDARD_TOOL_NAMES) expect(isStandardTool(n)).toBe(true);
    expect(isStandardTool('nope')).toBe(false);
    await expect(runStandardTool('not_a_tool', {}, host)).resolves.toBeNull();
  });

  it('validates required arguments instead of throwing', async () => {
    expect(await run('ask_user_question', {})).toMatch(/question is required/);
    expect(await run('todo_write', { todos: 'nope' })).toMatch(/todos must be an array/);
    expect(await run('create_goal', {})).toMatch(/objective is required/);
    expect(await run('run_code', { language: 'python' })).toMatch(/code is required/);
    expect(await run('run_code', { language: 'cobol', code: 'x' })).toMatch(/unsupported language/);
    expect(await run('read_image', {})).toMatch(/path is required/);
    expect(await run('web_fetch', { url: 'file:///etc/passwd' })).toMatch(/must be http/);
    expect(await run('present', {})).toMatch(/title or body is required/);
    expect(await run('schedule_create', { at: 'soon' })).toMatch(/prompt is required/);
    expect(await run('schedule_create', { prompt: 'x', at: 'not-a-date' })).toMatch(/at must be/);
    expect(await run('team_task_create', {})).toMatch(/subject is required/);
  });

  it('reports unknown ids for every store', async () => {
    expect(await run('job_output', { id: 'job-9' })).toMatch(/no job/);
    expect(await run('job_kill', { id: 'job-9' })).toMatch(/no job/);
    expect(await run('schedule_update', { id: 'sch-9' })).toMatch(/no schedule/);
    expect(await run('schedule_delete', { id: 'sch-9' })).toMatch(/no schedule/);
    expect(await run('team_task_update', { id: 't9' })).toMatch(/no team task/);
    expect(await run('skill', { name: 'missing' })).toMatch(/no skill "missing"/);
  });

  it('lists empty stores as empty, not as errors', async () => {
    expect(await run('schedule_list')).toBe('(no schedules)');
    expect(await run('job_list')).toBe('(no jobs)');
    expect(await run('team_task_list')).toBe('(no team tasks)');
    expect(await run('get_goal')).toMatch(/No goal is set/);
    expect(await run('update_goal', { status: 'complete' })).toMatch(/no goal is set/);
    expect(await run('list_agents')).toContain('s#sub-1');   // parent link visible
  });

  it('rejects a bad goal status and a bad skill name', async () => {
    await run('create_goal', { objective: 'x' });
    expect(await run('update_goal', { status: 'nope' })).toMatch(/status must be/);
    await writeSkill(path.join(dir, '.trha', 'skills'), 'lean', '# lean');
    process.env.TRHA_SKILLS_DIR = path.join(dir, '.trha', 'skills');
    expect(await run('skill')).toContain('lean');
    expect(await run('skill', { name: '../etc' })).toMatch(/ERROR/);
    delete process.env.TRHA_SKILLS_DIR;
  });

  it('job_output shows a running job; kill is idempotent', async () => {
    const id = startJob(host, 'echo guard-job');
    expect(await run('job_output', { id })).toMatch(/status: (running|exited)/);
    await run('job_kill', { id });
    expect(await run('job_kill', { id })).toMatch(/already exited|killed/);
    expect(await run('job_list')).toContain(id);
  });

  it('read_image rejects oversize and missing files', async () => {
    await writeFile(path.join(dir, 'huge.bin'), Buffer.alloc(3 * 1024 * 1024));
    expect(await run('read_image', { path: 'huge.bin' })).toMatch(/cap is 2 MiB/);
    expect(await run('read_image', { path: 'nope.png' })).toMatch(/^ERROR:/);
  });

  it('browser tools report a launch failure without throwing', async () => {
    process.env.TRHA_BROWSER = '/nonexistent/browser-binary';
    const out = await run('browser_navigate', { url: 'http://127.0.0.1:1/' });
    delete process.env.TRHA_BROWSER;
    expect(out).toMatch(/^ERROR:/);
  });

  it('browser_close is safe when nothing was opened', async () => {
    expect(await run('browser_close')).toMatch(/^OK: browser closed/);
  });
});

describe('todo_write is idempotent', () => {
  let dir: string;
  let host: StandardToolHost;
  beforeEach(async () => {
    dir = await mkdtemp(path.join(tmpdir(), 'trha-todo-'));
    host = { workspace: dir, state: {}, jobs: new Map(), sessionId: 's' };
  });
  afterEach(async () => { await rm(dir, { recursive: true, force: true }); });

  const list = (statuses: string[]): Array<{ text: string; status: string }> =>
    statuses.map((s, i) => ({ text: `task ${i + 1}`, status: s }));

  it('rejects an identical rewrite and leaves the stored list alone', async () => {
    const first = await runStandardTool('todo_write', { todos: list(['pending', 'completed']) }, host);
    expect(first).toMatch(/^OK: 2 todos/);
    const stored = host.state.todos;
    const again = await runStandardTool('todo_write', { todos: list(['pending', 'completed']) }, host);
    expect(again).toMatch(/^UNCHANGED: 2 todos/);
    // no state churn at all: same object, not a rebuilt copy
    expect(host.state.todos).toBe(stored);
  });

  it('treats reordering as unchanged but a status change as a real write', async () => {
    await runStandardTool('todo_write', { todos: [
      { text: 'a', status: 'pending' },
      { text: 'b', status: 'pending' },
    ] }, host);
    const reordered = await runStandardTool('todo_write', { todos: [
      { text: 'b', status: 'pending' },
      { text: 'a', status: 'pending' },
    ] }, host);
    expect(reordered).toMatch(/^UNCHANGED/);

    const changed = await runStandardTool('todo_write', { todos: [
      { text: 'a', status: 'completed' },
      { text: 'b', status: 'pending' },
    ] }, host);
    expect(changed).toMatch(/^OK: 2 todos/);
    expect(changed).toContain('[x] a');
  });
});
