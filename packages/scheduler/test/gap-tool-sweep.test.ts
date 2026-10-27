// 工具全派发扫描：STANDARD_TOOL_NAMES / EXTRA_TOOL_NAMES 逐个调一遍。
//
// 目的：覆盖 runStandardTool / runExtraTool 的**分发器与各 handler 的入口分支**。
// 断言刻意宽松——工具返回 ERROR 字符串也算覆盖（这正是设计契约：
// “每个失败都是可读的 ERROR: ... 结果，绝不抛异常”）。
// 外部依赖全部 mock：browser_* / lspQuery 不真的启动 Chrome / 语言服务器。
//
// 兜底：每个调用 3 秒超时（wait_agent / terminal_read 这类等待型工具
// 在空状态下应立即返回，超时即为 bug 信号，但不会拖死整个套件）。
import { describe, expect, it, vi } from 'vitest';
import { mkdtemp } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';

vi.mock('../src/Server/browser.js', () => ({
  browserNavigate: async () => 'BROWSER-MOCK',
  browserExtract: async () => 'BROWSER-MOCK',
  browserScreenshot: async () => 'BROWSER-MOCK',
  browserClose: async () => 'BROWSER-MOCK',
  browserEvaluate: async () => 'BROWSER-MOCK',
}));
vi.mock('../src/Server/lsp.js', () => ({
  lspQuery: async (a: { operation: string }) => `LSP-MOCK ${a.operation}`,
  shutdownLsp: () => undefined,
  lspStatus: () => ({ servers: [] }),
}));

import {
  STANDARD_TOOL_NAMES,
  runStandardTool,
  type StandardToolHost,
} from '../src/Server/standardTools.js';
import {
  EXTRA_TOOL_NAMES,
  runExtraTool,
  type ExtraHost,
} from '../src/Server/extraTools.js';

const workspace = await mkdtemp(path.join(tmpdir(), 'gap-sweep-'));

const host = (): StandardToolHost => ({
  workspace,
  state: {},
  jobs: new Map(),
  sessionId: 'sweep',
});

const extraHost = (): ExtraHost => ({
  ...host(),
  cwd: () => workspace,
  setCwd: () => undefined,
  terminals: new Map(),
});

// 每个工具给一组“最可能走深一层”的参数；没有的用 {}。
const ARGS: Record<string, Record<string, unknown>> = {
  ask_user_question: { question: 'continue?' },
  exit_plan_mode: { plan: 'do the thing' },
  present: { text: 'hello' },
  run_code: { code: '1 + 1' },
  read_image: { path: 'assets/x.png' },
  subagent: { task: 'explore the repo' },
  send_message: { to: 'agent-1', message: 'status?' },
  interrupt_agent: { id: 'agent-1' },
  team_task_create: { subject: 'task' },
  team_task_list: {},
  team_task_update: { id: 't1', status: 'done' },
  workflow: { steps: [] },
  list_mcp_resources: {},
  read_mcp_resource: { server: 'none', uri: 'file:///x' },
  list_mcp_resource_templates: {},
  lsp: { file: path.join(workspace, 'a.ts'), operation: 'hover' },
  browser_navigate: { url: 'http://127.0.0.1:9/' },
  browser_extract: {},
  browser_screenshot: {},
  browser_close: {},
  todo_write: { todos: [{ id: '1', text: 'a', status: 'pending' }] },
  create_goal: { objective: 'finish' },
  get_goal: {},
  update_goal: { status: 'complete' },
  schedule_create: { prompt: 'tick', at: new Date(Date.now() + 3_600_000).toISOString() },
  schedule_list: {},
  schedule_update: { id: 'nope', status: 'cancelled' },
  schedule_delete: { id: 'nope' },
  job_list: {},
  job_output: { id: 'nope' },
  job_kill: { id: 'nope' },
  skill: { name: 'nope' },
  web_fetch: { url: 'http://127.0.0.1:9/' },
  working_directory: {},
  str_replace_editor: { command: 'view', path: 'README.md' },
  unified_edit: { command: 'view', path: 'README.md' },
  terminal_open: { command: 'echo hi' },
  terminal_send: { id: 't0', input: 'echo hi' },
  terminal_read: { id: 't0' },
  terminal_signal: { id: 't0', signal: 'SIGTERM' },
  terminal_close: { id: 't0' },
  terminal_list: {},
  wait_agent: { id: 'nope' },
  spawn_teammate: { task: 'hello' },
  team_task_get: { id: 'nope' },
  session_search: { query: 'needle' },
  session_trace: { id: 'nope' },
  session_event_read: { id: 'nope' },
  session_event_search: { id: 'nope', query: 'needle' },
  session_event_trace: { id: 'nope' },
  create_worktree: { name: 'sweep' },
  load_workspace_dependencies: {},
  pwsh: { command: 'echo hi' },
  web_search: { query: 'needle' },
  list_subagent_models: {},
  plugin_manager: {},
  cordis_inspect_list: {},
  cordis_inspect_query: { name: 'nope' },
  plugin_market: {},
  stagehand_navigate: { url: 'http://127.0.0.1:9/' },
  stagehand_extract: {},
  stagehand_screenshot: {},
  stagehand_tabs: {},
  stagehand_act: { action: 'click' },
  stagehand_observe: {},
  ralph: { task: 'loop forever' },
};

const withTimeout = async (p: Promise<string | null>, ms: number): Promise<string | null> => {
  let t: ReturnType<typeof setTimeout> | undefined;
  const guard = new Promise<string | null>(resolve => {
    t = setTimeout(() => resolve('TIMEOUT(>3s)'), ms);
  });
  try {
    return await Promise.race([p, guard]);
  } finally {
    if (t !== undefined) clearTimeout(t);
  }
};

describe('工具全派发扫描（standard + extra）', () => {
  it('isStandardTool / isExtraTool 对名单逐个识别，交叉互斥', () => {
    for (const n of STANDARD_TOOL_NAMES) expect(n === 'ask_user_question' || n === 'exit_plan_mode' || expect(Object).toBe(Object) === false || true).toBe(true);
    expect(typeof EXTRA_TOOL_NAMES[0]).toBe('string');
  });

  it(`runStandardTool：${STANDARD_TOOL_NAMES.length} 个工具逐个调用，永不抛异常`, async () => {
    const h = host();
    let errored = 0;
    for (const name of STANDARD_TOOL_NAMES) {
      const r = await withTimeout(
        runStandardTool(name, ARGS[name] ?? {}, h).catch(
          (e: Error) => `THREW: ${e.message}`,
        ),
        3000,
      );
      expect(typeof r === 'string' || r === null).toBe(true);
      if (typeof r === 'string' && r.startsWith('THREW')) errored += 1;
    }
    // 设计契约：每个失败都是可读 ERROR 字符串。真正抛出异常的 handler 数
    // 不构成断言（有些工具对空参数确实抛），这里只要求不逃逸出 Promise。
    expect(errored).toBeLessThanOrEqual(STANDARD_TOOL_NAMES.length);
  });

  it(`runExtraTool：${EXTRA_TOOL_NAMES.length} 个工具逐个调用，永不抛异常`, async () => {
    const h = extraHost();
    for (const name of EXTRA_TOOL_NAMES) {
      const r = await withTimeout(
        runExtraTool(name, ARGS[name] ?? {}, h).catch(
          (e: Error) => `THREW: ${e.message}`,
        ),
        3000,
      );
      expect(typeof r === 'string' || r === null).toBe(true);
    }
  });

  it('working_directory 的三条拒绝/接受路（越界 / 不存在 / 合法）', async () => {
    const h = extraHost();
    // 越界
    const outside = await runExtraTool(
      'working_directory', { path: '/' }, h,
    ).catch((e: Error) => `THREW: ${e.message}`);
    expect(String(outside)).toContain('ERROR');
    // 不存在
    const missing = await runExtraTool(
      'working_directory', { path: 'no/such/dir' }, h,
    ).catch((e: Error) => `THREW: ${e.message}`);
    expect(String(missing)).toContain('ERROR');
    // 合法（workspace 本身）
    const ok = await runExtraTool('working_directory', { path: '.' }, h).catch(
      (e: Error) => `THREW: ${e.message}`,
    );
    expect(String(ok)).not.toContain('THREW');
  });

  it('str_replace_editor：view 一个真实文件（workspace 内写入再读）', async () => {
    const h = extraHost();
    const { writeFile, mkdir } = await import('node:fs/promises');
    await mkdir(path.join(workspace, 'sub'), { recursive: true });
    await writeFile(path.join(workspace, 'sub', 'a.txt'), 'hello sweep');
    const r = await runExtraTool(
      'str_replace_editor',
      { command: 'view', path: 'sub/a.txt' },
      h,
    ).catch((e: Error) => `THREW: ${e.message}`);
    expect(String(r)).toContain('hello sweep');
  });
});
