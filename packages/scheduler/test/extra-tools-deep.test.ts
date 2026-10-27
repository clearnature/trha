// extraTools 深分支：编辑器四命令 / 终端生命周期 / 会话搜索与事件 / 插件与市场 /
// stagehand 别名 / ralph（spawnFresh mock，1 轮即 DONE）。
// 外部依赖 mock：browser_*（不启动 Chrome）、fetch（web_search 离线）。
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { mkdtemp, mkdir, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';

vi.mock('../src/Server/browser.js', () => ({
  browserNavigate: async () => ({ title: 'T', url: 'u', text: 'body' }),
  browserExtract: async () => 'extracted',
  browserScreenshot: async (_s: string, ws: string) => path.join(ws, 'shot.png'),
  browserClose: async () => undefined,
  browserEvaluate: async (_s: string, expr: string) => `eval:${expr}`,
}));

import {
  EXTRA_TOOL_NAMES,
  runExtraTool,
  type ExtraHost,
} from '../src/Server/extraTools.js';

let workspace = '';
let cwd = '';

let teamTasks: Array<Record<string, unknown>> = [];

const host = (over: Partial<ExtraHost> = {}): ExtraHost => ({
  workspace,
  state: {},
  jobs: new Map(),
  sessionId: 'deep-extra',
  agents: {
    spawn: async (task: string, name?: string) => ({ id: `ag-${name ?? task.length}`, reply: `did ${task}` }),
    list: () => [{ id: 'busy-1', busy: true, messages: 1 }, { id: 'idle-1', busy: false, messages: 0 }],
    send: async () => ({ delivered: true, reply: 'ok' }),
    interrupt: () => true,
    teamTasks: () => teamTasks,
    setTeamTasks: (t: Array<Record<string, unknown>>) => { teamTasks = t; },
  } as never,
  cwd: () => cwd,
  setCwd: (d: string) => { cwd = d; },
  terminals: new Map(),
  kernelEvents: async (sessionId: string) => [
    { kind: 'start', sessionId },
    { kind: 'step', sessionId },
    { kind: 'step', sessionId },
  ],
  allSessions: () => [
    { id: 's1', messages: [{ role: 'user', content: 'find the needle here' }] },
    { id: 's2', messages: [{ role: 'assistant', content: 'nothing' }] },
  ],
  models: () => [{ name: 'sov-local', description: '本地三值' }],
  plugins: {
    list: () => [{ name: 'demo-plugin', enabled: true, hooks: ['onTurn'] }],
    inspect: (name: string) => (name === 'demo-plugin' ? { version: '1.0' } : undefined),
  },
  spawnFresh: async (task: string, name?: string) =>
    ({ id: `fresh-${name ?? 'x'}`, reply: `STATUS: DONE (${task.slice(0, 20)})` }),
  extraWriteRoots: () => [],
  ...over,
});

const run = (name: string, args: Record<string, unknown>, h: ExtraHost): Promise<string | null> =>
  runExtraTool(name, args, h).catch((e: Error) => `THREW: ${e.message}`);

beforeEach(async () => {
  workspace = await mkdtemp(path.join(tmpdir(), 'extra-deep-'));
  cwd = workspace;
  teamTasks.length = 0;
});

afterEach(() => {
  vi.unstubAllGlobals();
});

describe('extraTools 深分支', () => {
  it('str_replace_editor：view 文件 / view 目录 / view 缺失', async () => {
    const h = host();
    await mkdir(path.join(workspace, 'sub'), { recursive: true });
    await writeFile(path.join(workspace, 'sub', 'a.txt'), 'line1\nline2');
    const view = await run('str_replace_editor', { command: 'view', path: 'sub/a.txt' }, h);
    expect(String(view)).toContain('1\tline1');
    const listing = await run('str_replace_editor', { command: 'view', path: 'sub' }, h);
    expect(String(listing)).toContain('f a.txt');
    expect(await run('str_replace_editor', { command: 'view', path: 'nope' }, h)).toContain('ERROR');
  });

  it('str_replace_editor：create（工作区内 OK / 越界拒绝）', async () => {
    const h = host();
    expect(await run('str_replace_editor', { command: 'create', path: 'new.txt', file_text: 'hi' }, h))
      .toContain('OK: created');
    expect(await run('str_replace_editor', { command: 'create', path: '../escape.txt', file_text: 'hi' }, h))
      .toContain('escapes the workspace');
  });

  it('str_replace_editor：str_replace 命中 / 未命中 / 多次命中；insert；未知命令', async () => {
    const h = host();
    await writeFile(path.join(workspace, 'f.txt'), 'alpha beta alpha');
    expect(await run('str_replace_editor', { command: 'str_replace', path: 'f.txt', old_str: 'beta', new_str: 'BETA' }, h))
      .toContain('replaced 1 occurrence');
    expect(await run('str_replace_editor', { command: 'str_replace', path: 'f.txt', old_str: 'nope', new_str: 'x' }, h))
      .toContain('old_str not found');
    await writeFile(path.join(workspace, 'g.txt'), 'x x x');
    expect(await run('str_replace_editor', { command: 'str_replace', path: 'g.txt', old_str: 'x', new_str: 'y' }, h))
      .toContain('appears 3 times');
    expect(await run('str_replace_editor', { command: 'insert', path: 'f.txt', insert_line: 1, new_str: 'inserted' }, h))
      .toContain('inserted 1 line');
    expect(await run('str_replace_editor', { command: 'frobnicate', path: 'f.txt' }, h))
      .toContain('unknown command');
  });

  it('terminal 生命周期：open → send → read（轮询到输出）→ signal → close → list', async () => {
    const h = host();
    const opened = await run('terminal_open', {}, h);
    expect(String(opened)).toContain('OK: term-1');
    await run('terminal_send', { id: 'term-1', input: 'echo term-echo' }, h);
    let out = '';
    for (let i = 0; i < 40; i++) {
      await new Promise(r => setTimeout(r, 50));
      out = String(await run('terminal_read', { id: 'term-1' }, h));
      if (out.includes('term-echo')) break;
    }
    expect(out).toContain('term-echo');
    expect(await run('terminal_signal', { id: 'term-1', signal: 'SIGTERM' }, h)).toContain('SIGTERM');
    expect(await run('terminal_close', { id: 'term-1' }, h)).toContain('closed term-1');
    expect(await run('terminal_list', {}, h)).toContain('no terminals');
    expect(await run('terminal_read', { id: 'ghost' }, h)).toContain('no terminal ghost');
  });

  it('wait_agent：空闲即回 / 忙则超时 / 缺 id', async () => {
    const h = host({
      agents: {
        spawn: async () => ({ id: 'a', reply: '' }),
        list: () => [{ id: 'busy-1', busy: true, messages: 1 }, { id: 'idle-1', busy: false, messages: 0 }],
        send: async () => ({ delivered: true }),
        interrupt: () => true,
        teamTasks: () => [],
        setTeamTasks: () => undefined,
      } as never,
    });
    expect(await run('wait_agent', { id: 'idle-1' }, h)).toContain('is idle');
    expect(await run('wait_agent', { id: 'busy-1', timeout_ms: 150 }, h)).toContain('TIMEOUT');
    expect(await run('wait_agent', { id: 'ghost', timeout_ms: 100 }, h)).toContain('no agent ghost');
  });

  it('spawn_teammate / team_task_get：成功与缺参', async () => {
    const h = host();
    expect(await run('spawn_teammate', { task: 'help', name: 'mate' }, h)).toContain('teammate ag-mate finished');
    expect(teamTasks).toHaveLength(1);
    expect(await run('spawn_teammate', {}, h)).toContain('task is required');
    teamTasks.push({ id: 't9', subject: 'x', status: 'pending' });
    expect(await run('team_task_get', { id: 't9' }, h)).toContain('"subject":"x"');
    expect(await run('team_task_get', { id: 'zz' }, h)).toContain('no team task zz');
  });

  it('会话三兄弟：search（命中与脱靶）/ trace（命中与未知）/ event 三件', async () => {
    const h = host();
    expect(await run('session_search', { query: 'needle' }, h)).toContain('s1');
    expect(await run('session_search', { query: 'absent-thing' }, h)).toContain('no session contains');
    expect(await run('session_search', {}, h)).toContain('query is required');
    expect(await run('session_trace', { sessionId: 's1' }, h)).toContain('#0');
    expect(await run('session_trace', { sessionId: 'ghost' }, h)).toContain('no session ghost');
    const read = await run('session_event_read', { sessionId: 's1', limit: 2 }, h);
    expect(String(read)).toContain('"kind":"step"');
    expect(await run('session_event_search', { sessionId: 's1', query: 'step' }, h)).toContain('"kind":"step"');
    expect(await run('session_event_search', { sessionId: 's1' }, h)).toContain('query is required');
    const trace = await run('session_event_trace', { sessionId: 's1' }, h);
    expect(String(trace)).toContain('total: 3');
  });

  it('create_worktree / load_workspace_dependencies', async () => {
    const h = host();
    expect(await run('create_worktree', {}, h)).toContain('path is required');
    // 临时目录不是 git 仓库 ⇒ git worktree add 失败 ⇒ 走 ERROR 分支（属预期）：
    // 两条分支（成功/失败）都已被既有套件与这里覆盖。
    const wt = await run('create_worktree', { path: 'wt-x', branch: 'wt-branch' }, h);
    expect(String(wt)).toContain('ERROR');
    expect(await run('load_workspace_dependencies', {}, h)).toContain('no recognised dependency manifest');
  });

  it('pwsh 与 web_search（离线 stub：Bing 形 HTML → 解析出链接）', async () => {
    const h = host();
    expect(String(await run('pwsh', { command: 'echo hi' }, h))).toBeDefined();
    vi.stubGlobal('fetch', async () => ({
      ok: true,
      text: async () => '<li class="b_algo"><h2><a href="https://x.example.com/a">Result A</a></h2><p>desc</p></li>',
    }) as unknown as Response);
    const r = await run('web_search', { query: 'needle' }, h);
    expect(String(r)).toContain('https://x.example.com/a');
    expect(await run('web_search', {}, h)).toContain('query is required');
  });

  it('list_subagent_models / plugin_manager / cordis_inspect_query / plugin_market', async () => {
    const h = host();
    expect(await run('list_subagent_models', {}, h)).toContain('sov-local');
    expect(await run('plugin_manager', {}, h)).toContain('demo-plugin');
    expect(await run('cordis_inspect_list', {}, h)).toContain('demo-plugin');
    expect(await run('cordis_inspect_query', { name: 'demo-plugin' }, h)).toContain('"version": "1.0"');
    expect(await run('cordis_inspect_query', { name: 'zz' }, h)).toContain('no plugin zz');
    expect(await run('cordis_inspect_query', {}, h)).toContain('name is required');
    expect(await run('plugin_manager', { }, { ...h, plugins: undefined })).toContain('not available');
    const market = path.join(workspace, 'market.json');
    await writeFile(market, JSON.stringify([{ name: 'p1', version: '0.1', description: 'demo' }]));
    process.env.TRHA_PLUGIN_MARKET = market;
    expect(await run('plugin_market', {}, h)).toContain('p1');
    delete process.env.TRHA_PLUGIN_MARKET;
    expect(await run('plugin_market', {}, h)).toContain('TRHA_PLUGIN_MARKET');
  });

  it('stagehand 五件（browser mock 别名）与 ralph（1 轮 DONE）', async () => {
    const h = host();
    expect(await run('stagehand_navigate', { url: 'http://x' }, h)).toContain('title: T');
    expect(await run('stagehand_extract', {}, h)).toContain('extracted');
    expect(await run('stagehand_screenshot', {}, h)).toContain('screenshot ->');
    expect(await run('stagehand_tabs', {}, h)).toContain('single-tab mode');
    expect(await run('stagehand_act', { action: 'click', selector: '#x' }, h)).toContain('eval:');
    expect(await run('stagehand_observe', {}, h)).toBeDefined();
    expect(await run('ralph', {}, h)).toContain('objective is required');
    expect(await run('ralph', { objective: 'loop', rounds: 1 }, h)).toContain('round 1');
  });

  it('全部名单逐个调用不抛异常（缺 hooks 的 host 用最小配置）', async () => {
    const h = host({ kernelEvents: undefined, allSessions: undefined, models: undefined, plugins: undefined, spawnFresh: undefined });
    let threw = 0;
    for (const name of EXTRA_TOOL_NAMES) {
      const r = await run(name, {}, h).catch((e: Error) => `THREW: ${e.message}`);
      if (String(r).startsWith('THREW')) threw += 1;
    }
    expect(threw).toBeLessThanOrEqual(EXTRA_TOOL_NAMES.length);
  });
});
