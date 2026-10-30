// Remaining dsh standard tools, ported by semantics.
//
// Kept out of standardTools.ts only for size; same contract: every failure is a
// readable `ERROR: ...` result, never a thrown exception.
//
// Needs external services: web_search (SearXNG / DuckDuckGo), plugin_market
// (TRHA_PLUGIN_MARKET), stagehand_* (shares the CDP browser with browser_*).

import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import { mkdir, readdir, readFile, stat, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { confineWritePath } from './toolGuard.js';
import { browserEvaluate, browserExtract, browserNavigate, browserScreenshot } from './browser.js';
import { hardenedEnv, interactiveShell, powerShellCandidates, resolveShell } from './shell.js';
import { defaultSandboxScope, sandboxBlocksNetwork, sandboxEnabled, sandboxedInteractive, sandboxedSpawn, type SandboxSession } from './sandbox.js';
import { registerTool, renderToolValue, resolveTool } from './toolRegistry.js';
import { defineTool, oneLine, textBlock, toolSpecFrom } from './toolSchema.js';
import type { StandardToolHost, TeamTask } from './standardTools.js';

export interface Terminal {
  id: string;
  output: string;
  status: 'running' | 'exited';
  exitCode?: number;
  /** Feed stdin — works for a local child and for a sandboxed session alike. */
  write(data: string): void;
  /** Terminate the shell (sandboxed sessions terminate as a whole). */
  kill(signal?: NodeJS.Signals): void;
}

export interface ExtraHost extends StandardToolHost {
  /** Session cwd, relative to (or inside) the workspace. */
  cwd: () => string;
  setCwd: (dir: string) => void;
  /**
   * The session's workspace root — what `cwd` must stay inside.  Distinct from
   * `workspace` (the process-wide one): with several clients on different
   * projects, the process has no idea which project this session belongs to.
   */
  workspaceRoot?: () => string;
  terminals: Map<string, Terminal>;
  /** Kernel event log for a session (empty when the kernel is unreachable). */
  kernelEvents?: (sessionId: string) => Promise<Array<Record<string, unknown>>>;
  /** All sessions, for cross-session search/trace. */
  allSessions?: () => Array<{ id: string; messages: Array<{ role: string; content: string }> }>;
  /** Running subagent models, from the provider registry. */
  models?: () => Array<{ name: string; description?: string }>;
  plugins?: {
    list: () => Array<{ name: string; enabled: boolean; hooks: string[] }>;
    inspect: (name: string) => unknown;
  };
  /** Spawn a fresh child (used by ralph, one per round). */
  spawnFresh?: (task: string, name?: string) => Promise<{ id: string; reply: string }>;
  /** Extra trusted write roots from the sandbox settings page (same as write/edit). */
  extraWriteRoots?: () => string[];
}

export const EXTRA_TOOL_NAMES = [
  'working_directory', 'str_replace_editor', 'unified_edit',
  'terminal_open', 'terminal_send', 'terminal_read', 'terminal_signal', 'terminal_close', 'terminal_list',
  'wait_agent', 'spawn_teammate', 'team_task_get',
  'session_search', 'session_trace', 'session_event_read', 'session_event_search', 'session_event_trace',
  'create_worktree', 'load_workspace_dependencies', 'pwsh',
  'web_search', 'list_subagent_models', 'plugin_manager', 'cordis_inspect_list', 'cordis_inspect_query',
  'plugin_market',
  'stagehand_navigate', 'stagehand_extract', 'stagehand_screenshot', 'stagehand_tabs', 'stagehand_act', 'stagehand_observe',
  'ralph',
] as const;

export function isExtraTool(name: string): boolean {
  return (EXTRA_TOOL_NAMES as readonly string[]).includes(name);
}

const clip = (s: string, cap = 20_000): string =>
  s.length <= cap ? s : `${s.slice(0, cap)}\n…(${s.length - cap} more chars)`;

const sh = (host: ExtraHost, cmd: string): Promise<{ code: number; out: string }> => {
  const shell = resolveShell(cmd);
  // Compatibility default: TRHA_SANDBOX=off keeps the direct spawn below.
  if (sandboxEnabled()) {
    return sandboxedSpawn(defaultSandboxScope(host.cwd()), {
      argv: [shell.cmd, ...shell.args],
      cwd: host.cwd(),
    })
      .then(r => ({ code: r.code ?? 1, out: r.stdout + r.stderr }))
      .catch((e: Error) => ({ code: 127, out: e.message }));
  }
  return new Promise(resolve => {
    const child = spawn(shell.cmd, shell.args, { cwd: host.cwd(), ...shell.options, env: hardenedEnv() });
    const out: string[] = [];
    child.stdout.on('data', (b: Buffer) => out.push(b.toString('utf8')));
    child.stderr.on('data', (b: Buffer) => out.push(b.toString('utf8')));
    child.on('error', e => resolve({ code: 127, out: e.message }));
    child.on('exit', code => resolve({ code: code ?? -1, out: out.join('') }));
  });
};

export async function runExtraTool(
  name: string,
  args: Record<string, unknown>,
  host: ExtraHost,
): Promise<string | null> {
  // Same precedence rule as `runStandardTool`: registered plugins first, the
  // legacy chain as the fallback for anything not migrated yet.
  const registered = resolveTool(name);
  if (registered?.handler) return renderToolValue(registered, args, host);

  // ── working directory ────────────────────────────────────────────────
  // Migrated to the registry (full DSH contract), so the chain no longer
  // handles it — `resolveTool` above always wins for this name.

  // ── editor-style file ops (dsh's str_replace_editor / unified_edit) ──
  if (name === 'str_replace_editor' || name === 'unified_edit') {
    // Migrated to the registry (full DSH contract): two definitions sharing one
    // implementation.
  }

  // ── persistent terminals ─────────────────────────────────────────────
  if (name === 'terminal_open') {
    // Migrated to the registry (full DSH contract); `resolveTool` wins for this name.
  }
  if (name === 'terminal_send') {
    // Migrated to the registry (full DSH contract); `resolveTool` wins for this name.
  }
  if (name === 'terminal_read') {
    // Migrated to the registry (full DSH contract); `resolveTool` wins for this name.
  }
  if (name === 'terminal_signal') {
    // Migrated to the registry (full DSH contract); `resolveTool` wins for this name.
  }
  if (name === 'terminal_close') {
    // Migrated to the registry (full DSH contract); `resolveTool` wins for this name.
  }
  if (name === 'terminal_list') {
    // Migrated to the registry (full DSH contract); `resolveTool` wins for this name.
  }

  // ── agents ───────────────────────────────────────────────────────────
  if (name === 'wait_agent' || name === 'spawn_teammate') {
    // Migrated to the registry (full DSH contract): two separate tools now.
  }
  if (name === 'team_task_get') {
    // Migrated to the registry (full DSH contract); `resolveTool` wins for this
    // name, so the chain never reaches here.
  }

  // ── sessions ─────────────────────────────────────────────────────────
  if (name === 'session_search') {
    // Migrated to the registry (full DSH contract); `resolveTool` wins for this
    // name, so the chain never reaches here.
  }
  if (name === 'session_trace') {
    // Migrated to the registry (full DSH contract).
  }
  if (name === 'session_event_read' || name === 'session_event_search' || name === 'session_event_trace') {
    // Migrated to the registry (full DSH contract): three separate tools now.
  }

  // ── repo / env ───────────────────────────────────────────────────────
  if (name === 'create_worktree') {
    // Migrated to the registry (full DSH contract); `resolveTool` wins for this name.
  }
  if (name === 'load_workspace_dependencies') {
    // Migrated to the registry (full DSH contract).
  }
  if (name === 'pwsh') {
    // Migrated to the registry (full DSH contract); `resolveTool` wins for this name.
  }
  // ── search / models / plugins ────────────────────────────────────────
  if (name === 'web_search') {
    // Migrated to the registry (full DSH contract); `resolveTool` wins for this name.
  }
  if (name === 'list_subagent_models') {
    // Migrated to the registry (full DSH contract).
  }
  if (name === 'plugin_manager' || name === 'cordis_inspect_list') {
    // Migrated to the registry (full DSH contract); `resolveTool` wins for this name.
  }
  if (name === 'cordis_inspect_query') {
    // Migrated to the registry (full DSH contract).
  }
  if (name === 'plugin_market') {
    // Migrated to the registry (full DSH contract).
  }

  // ── stagehand aliases (same CDP browser as browser_*) ────────────────
  if (name === 'stagehand_navigate') {
    // Migrated to the registry (full DSH contract); `resolveTool` wins for this name.
  }
  if (name === 'stagehand_extract') {
    // Migrated to the registry (full DSH contract); `resolveTool` wins for this name.
  }
  if (name === 'stagehand_screenshot') {
    // Migrated to the registry (full DSH contract); `resolveTool` wins for this name.
  }
  if (name === 'stagehand_tabs') {
    // Migrated to the registry (full DSH contract); `resolveTool` wins for this name.
  }
  if (name === 'stagehand_observe') {
    // Migrated to the registry (full DSH contract); `resolveTool` wins for this name.
  }
  if (name === 'stagehand_act') {
    // Migrated to the registry (full DSH contract); `resolveTool` wins for this name.
  }

  // ── ralph loop ───────────────────────────────────────────────────────
  if (name === 'ralph') {
    // Migrated to the registry (full DSH contract); `resolveTool` wins for this
    // name, so the chain never reaches here.
  }

  return null;
}

// ── registered handlers (plugin migration) ────────────────────────────
//
// Migrated one tool at a time; anything without a handler still runs through
// the chain above. `toolDeclarations.ts` supplies the plane/preset metadata,
// `registerTool` upgrades that declaration with the handler.

/**
 * `working_directory` — the first tool on the **full DSH contract**.
 *
 * Compare `packages/session/tool-working-directory/src/index.ts` in
 * deepseek-harness: `defineTool` with `description` + `parameters` +
 * `output { schema, render }` + `execute(args, exec)`. Two deliberate
 * differences: trha keeps `path` as the parameter name (DSH uses `cd`) so
 * existing callers keep working, and the schema check happens at construction
 * rather than through TS inference.
 */
const workingDirectoryTool = defineTool<{ cwd: string }>({
  name: 'working_directory',
  description:
    'Read the current working directory, or change it by passing a path. Relative '
    + 'paths resolve against the current directory, and the result must stay inside '
    + 'the session workspace. Existing shells keep their own directories.',
  parameters: {
    path: {
      type: 'string',
      description: 'Existing directory to enter. Omit to read the current directory.',
    },
  },
  presentCall: args => ({ card: 'generic', title: `cd ${oneLine(args.path ?? '.')}` }),
  output: {
    schema: {
      type: 'object',
      additionalProperties: false,
      properties: { cwd: { type: 'string' } },
    },
    render: (_args, value) => [textBlock(value.cwd)],
  },
  async execute(args, exec) {
    const host = exec.host as ExtraHost;
    const want = typeof args.path === 'string' ? args.path.trim() : '';
    if (!want) return { cwd: host.cwd() };

    const target = path.resolve(host.cwd(), want);
    let info;
    try {
      info = await stat(target);
    } catch {
      throw new Error(`no such directory: ${target}`);
    }
    if (!info.isDirectory()) throw new Error(`not a directory: ${target}`);
    // Clamp to the *session's* workspace root, not the process-wide one:
    // with several clients on different projects, `WORKSPACE` belongs to
    // whoever happened to start the scheduler.
    const root = path.resolve(host.workspaceRoot?.() ?? host.workspace);
    if (target !== root && !target.startsWith(root + path.sep)) {
      throw new Error(`working directory must stay inside ${root}`);
    }
    host.setCwd(target);
    return { cwd: target };
  },
});

registerTool(toolSpecFrom(workingDirectoryTool, { plane: 'agent' }));

/** `team_task_get` — read one shared team task. */
const teamTaskGetTool = defineTool<string>({
  name: 'team_task_get',
  description: 'Read one shared team task by id.',
  parameters: { id: { type: 'string', description: 'Task id from team_task_list.' } },
  presentCall: args => ({ card: 'generic', title: `task ${oneLine(args.id)}` }),
  output: { schema: { type: 'string' }, render: (_args, value) => [textBlock(value)] },
  async execute(args, exec) {
    const host = exec.host as ExtraHost;
    if (!host.agents) throw new Error('team tasks are not available in this host');
    const id = typeof args.id === 'string' ? args.id : '';
    const t = host.agents.teamTasks().find(x => x.id === id);
    if (!t) throw new Error(`no team task ${id}`);
    return JSON.stringify(t);
  },
});

registerTool(toolSpecFrom(teamTaskGetTool, { plane: 'host' }));

/** `session_search` — grep every session transcript for a substring. */
const sessionSearchTool = defineTool<string>({
  name: 'session_search',
  description: 'Search every session transcript for a substring; one hit per session.',
  parameters: {
    query: { type: 'string', description: 'Substring to look for.' },
    limit: { type: 'number', description: 'Maximum sessions to report (default 20).' },
  },
  presentCall: args => ({ card: 'generic', title: `search sessions: ${oneLine(args.query)}` }),
  output: { schema: { type: 'string' }, render: (_args, value) => [textBlock(value)] },
  async execute(args, exec) {
    const host = exec.host as ExtraHost;
    const query = typeof args.query === 'string' ? args.query.trim() : '';
    if (!query) throw new Error('query is required');
    const limit = typeof args.limit === 'number' ? args.limit : 20;
    const hits: string[] = [];
    for (const s of host.allSessions?.() ?? []) {
      for (const [i, m] of s.messages.entries()) {
        if (typeof m.content === 'string' && m.content.includes(query)) {
          const at = m.content.indexOf(query);
          hits.push(`${s.id}\t#${i}\t${m.role}\t${m.content.slice(Math.max(0, at - 40), at + 80)}`);
          break;
        }
      }
      if (hits.length >= limit) break;
    }
    return hits.length ? clip(hits.join('\n')) : `(no session contains "${query}")`;
  },
});

/** `session_trace` — one session's messages, one line each. */
const sessionTraceTool = defineTool<string>({
  name: 'session_trace',
  description: 'Show one session\'s messages one line each (role + truncated text).',
  parameters: {
    sessionId: { type: 'string', description: 'Session id; defaults to the current one.' },
  },
  presentCall: args => ({ card: 'generic', title: `trace ${oneLine(args.sessionId)}` }),
  output: { schema: { type: 'string' }, render: (_args, value) => [textBlock(value)] },
  async execute(args, exec) {
    const host = exec.host as ExtraHost;
    const target = typeof args.sessionId === 'string' ? args.sessionId : host.sessionId;
    const s = (host.allSessions?.() ?? []).find(x => x.id === target);
    if (!s) throw new Error(`no session ${target}`);
    return clip(s.messages.map((m, i) =>
      `#${i}\t${m.role}\t${(m.content ?? '').slice(0, 120).replace(/\n/g, ' ')}`).join('\n'));
  },
});

/** `session_event_read` — the tail of one session's kernel event log. */
const sessionEventReadTool = defineTool<string>({
  name: 'session_event_read',
  description: 'Read the most recent kernel events for one session.',
  parameters: {
    sessionId: { type: 'string', description: 'Session id; defaults to the current one.' },
    limit: { type: 'number', description: 'How many events to return (default 20).' },
  },
  presentCall: _args => ({ card: 'generic', title: 'read events' }),
  output: { schema: { type: 'string' }, render: (_args, value) => [textBlock(value)] },
  async execute(args, exec) {
    const host = exec.host as ExtraHost;
    const target = typeof args.sessionId === 'string' ? args.sessionId : host.sessionId;
    const events = (await host.kernelEvents?.(target)) ?? [];
    if (events.length === 0) return '(no kernel events; kernel unreachable or session unknown)';
    const limit = typeof args.limit === 'number' ? args.limit : 20;
    return clip(events.slice(-limit).map(e => JSON.stringify(e)).join('\n'));
  },
});

/** `session_event_search` — grep one session's kernel event log. */
const sessionEventSearchTool = defineTool<string>({
  name: 'session_event_search',
  description: 'Search the kernel event log of one session for a substring.',
  parameters: {
    query: { type: 'string', description: 'Substring to look for.' },
    sessionId: { type: 'string', description: 'Session id; defaults to the current one.' },
  },
  presentCall: args => ({ card: 'generic', title: `search events: ${oneLine(args.query)}` }),
  output: { schema: { type: 'string' }, render: (_args, value) => [textBlock(value)] },
  async execute(args, exec) {
    const host = exec.host as ExtraHost;
    const target = typeof args.sessionId === 'string' ? args.sessionId : host.sessionId;
    const events = (await host.kernelEvents?.(target)) ?? [];
    if (events.length === 0) return '(no kernel events; kernel unreachable or session unknown)';
    const needle = typeof args.query === 'string' ? args.query : '';
    if (!needle) throw new Error('query is required');
    const hits = events.filter(e => JSON.stringify(e).includes(needle));
    return hits.length
      ? clip(hits.map(e => JSON.stringify(e)).join('\n'))
      : `(no event contains "${needle}")`;
  },
});

/** `session_event_trace` — count one session's kernel events by kind. */
const sessionEventTraceTool = defineTool<string>({
  name: 'session_event_trace',
  description: 'Summarise one session\'s kernel event log by event kind.',
  parameters: {
    sessionId: { type: 'string', description: 'Session id; defaults to the current one.' },
  },
  presentCall: _args => ({ card: 'generic', title: 'trace events' }),
  output: { schema: { type: 'string' }, render: (_args, value) => [textBlock(value)] },
  async execute(args, exec) {
    const host = exec.host as ExtraHost;
    const target = typeof args.sessionId === 'string' ? args.sessionId : host.sessionId;
    const events = (await host.kernelEvents?.(target)) ?? [];
    if (events.length === 0) return '(no kernel events; kernel unreachable or session unknown)';
    const counts = new Map<string, number>();
    for (const e of events) {
      const k = String((e as { kind?: unknown }).kind ?? '?');
      counts.set(k, (counts.get(k) ?? 0) + 1);
    }
    return [...counts.entries()].map(([k, n]) => `${k}: ${n}`).join('\n')
      + `\ntotal: ${events.length}`;
  },
});

registerTool(toolSpecFrom(sessionSearchTool, { plane: 'host' }));
registerTool(toolSpecFrom(sessionTraceTool, { plane: 'host' }));
registerTool(toolSpecFrom(sessionEventReadTool, { plane: 'host' }));
registerTool(toolSpecFrom(sessionEventSearchTool, { plane: 'host' }));
registerTool(toolSpecFrom(sessionEventTraceTool, { plane: 'host' }));

/** `terminal_open` — start a persistent shell (sandboxed when the seam is on). */
const terminalOpenTool = defineTool<string>({
  name: 'terminal_open',
  description:
    'Open a persistent shell. When the sandbox is enabled the shell runs inside it, '
    + 'driven over the same stdin-frame protocol as one-shot commands.',
  parameters: {},
  output: { schema: { type: 'string' }, render: (_args, value) => [textBlock(value)] },
  presentCall: _args => ({ card: 'terminal', title: 'open shell' }),
  async execute(_args, exec) {
    const host = exec.host as ExtraHost;
    const id = `term-${host.terminals.size + 1}`;
    const ish = interactiveShell();
    const term: Terminal = { id, output: '', status: 'running', write: () => {}, kill: () => {} };
    const push = (chunk: string): void => {
      term.output += chunk;
      if (term.output.length > 200_000) term.output = term.output.slice(-200_000);
    };

    // No bypass path when the seam is on: the persistent shell runs inside the
    // sandbox too, driven by stdin frames over the same NDJSON protocol as
    // one-shot commands. A runner failure is a failed tool call.
    if (sandboxEnabled()) {
      let session: SandboxSession;
      try {
        session = await sandboxedInteractive(defaultSandboxScope(host.cwd()), {
          argv: [ish.cmd, ...ish.args],
          cwd: host.cwd(),
          env: { PS1: '' },
        });
      } catch (e) {
        throw new Error(`sandboxed terminal unavailable: ${(e as Error).message}`);
      }
      term.write = (data: string) => session.write(data);
      term.kill = () => session.kill();
      session.onData(push);
      session.onExit(code => {
        term.status = 'exited';
        term.exitCode = code;
      });
      host.terminals.set(id, term);
      return `OK: ${id} (sandboxed shell ${session.id})`;
    }

    const child = spawn(ish.cmd, ish.args, {
      cwd: host.cwd(),
      // PS1 is a bash concept; PowerShell needs no prompt scrubbing
      env: hardenedEnv(undefined, process.platform === 'win32' ? process.env : { ...process.env, PS1: '' }),
      stdio: ['pipe', 'pipe', 'pipe'],
    }) as ChildProcessWithoutNullStreams;
    term.write = (data: string) => { child.stdin.write(data); };
    term.kill = (signal?: NodeJS.Signals) => { child.kill(signal); };
    child.stdout.on('data', (b: Buffer) => push(b.toString('utf8')));
    child.stderr.on('data', (b: Buffer) => push(b.toString('utf8')));
    child.on('exit', code => { term.status = 'exited'; term.exitCode = code ?? -1; });
    host.terminals.set(id, term);
    return `OK: ${id} (shell pid ${child.pid ?? '?'})`;
  },
});

/** `terminal_send` — write one line into a persistent shell. */
const terminalSendTool = defineTool<string>({
  name: 'terminal_send',
  description: 'Send input to a persistent shell. A trailing newline is added when missing.',
  parameters: {
    id: { type: 'string', description: 'Terminal id from terminal_open / terminal_list.' },
    input: { type: 'string', description: 'Text to type.' },
  },
  presentCall: args => ({ card: 'terminal', title: `send: ${oneLine(args.input)}` }),
  output: { schema: { type: 'string' }, render: (_args, value) => [textBlock(value)] },
  async execute(args, exec) {
    const host = exec.host as ExtraHost;
    const id = typeof args.id === 'string' ? args.id : '';
    const input = typeof args.input === 'string' ? args.input : '';
    const term = host.terminals.get(id);
    if (!term) throw new Error(`no terminal ${id}`);
    if (term.status !== 'running') throw new Error(`${id} has exited`);
    term.write(input.endsWith('\n') ? input : `${input}\n`);
    return `OK: sent ${input.length} chars to ${id}`;
  },
});

/** `terminal_read` — collected output of one shell. */
const terminalReadTool = defineTool<string>({
  name: 'terminal_read',
  description: 'Read a persistent shell\'s output, optionally from a character offset.',
  parameters: {
    id: { type: 'string', description: 'Terminal id.' },
    since: { type: 'number', description: 'Character offset to read from (default 0).' },
  },
  presentCall: args => ({ card: 'terminal', title: `read ${oneLine(args.id)}` }),
  output: { schema: { type: 'string' }, render: (_args, value) => [textBlock(value)] },
  async execute(args, exec) {
    const host = exec.host as ExtraHost;
    const id = typeof args.id === 'string' ? args.id : '';
    const term = host.terminals.get(id);
    if (!term) throw new Error(`no terminal ${id}`);
    const since = typeof args.since === 'number' ? args.since : 0;
    const chunk = term.output.slice(since);
    return clip(`status: ${term.status}${term.exitCode !== undefined ? ` exit=${term.exitCode}` : ''}\n${chunk || '(no output yet)'}`);
  },
});

/** `terminal_signal` — send a signal to one shell. */
const terminalSignalTool = defineTool<string>({
  name: 'terminal_signal',
  description: 'Signal a persistent shell (default SIGINT).',
  parameters: {
    id: { type: 'string', description: 'Terminal id.' },
    signal: { type: 'string', description: 'Signal name, e.g. SIGINT or SIGTERM.' },
  },
  presentCall: args => ({ card: 'terminal', title: `signal ${oneLine(args.signal)}` }),
  output: { schema: { type: 'string' }, render: (_args, value) => [textBlock(value)] },
  async execute(args, exec) {
    const host = exec.host as ExtraHost;
    const id = typeof args.id === 'string' ? args.id : '';
    const sig = typeof args.signal === 'string' ? args.signal : 'SIGINT';
    const term = host.terminals.get(id);
    if (!term) throw new Error(`no terminal ${id}`);
    term.kill(sig as NodeJS.Signals);
    return `OK: sent ${sig} to ${id}`;
  },
});

/** `terminal_close` — SIGTERM and forget one shell. */
const terminalCloseTool = defineTool<string>({
  name: 'terminal_close',
  description: 'Close a persistent shell.',
  parameters: { id: { type: 'string', description: 'Terminal id.' } },
  presentCall: args => ({ card: 'terminal', title: `close ${oneLine(args.id)}` }),
  output: { schema: { type: 'string' }, render: (_args, value) => [textBlock(value)] },
  async execute(args, exec) {
    const host = exec.host as ExtraHost;
    const id = typeof args.id === 'string' ? args.id : '';
    const term = host.terminals.get(id);
    if (!term) throw new Error(`no terminal ${id}`);
    term.kill('SIGTERM');
    host.terminals.delete(id);
    return `OK: closed ${id}`;
  },
});

/** `terminal_list` — every persistent shell on this session. */
const terminalListTool = defineTool<string>({
  name: 'terminal_list',
  description: 'List the persistent shells and how much output each holds.',
  parameters: {},
  presentCall: _args => ({ card: 'terminal', title: 'list terminals' }),
  output: { schema: { type: 'string' }, render: (_args, value) => [textBlock(value)] },
  async execute(_args, exec) {
    const host = exec.host as ExtraHost;
    if (host.terminals.size === 0) return '(no terminals)';
    return [...host.terminals.values()]
      .map(t => `${t.id}\t${t.status}\t${t.output.length} chars`).join('\n');
  },
});

registerTool(toolSpecFrom(terminalOpenTool, { plane: 'agent' }));
registerTool(toolSpecFrom(terminalSendTool, { plane: 'agent' }));
registerTool(toolSpecFrom(terminalReadTool, { plane: 'agent' }));
registerTool(toolSpecFrom(terminalSignalTool, { plane: 'agent' }));
registerTool(toolSpecFrom(terminalCloseTool, { plane: 'agent' }));
registerTool(toolSpecFrom(terminalListTool, { plane: 'agent' }));

/** `ralph` — run the objective N times, each round starting fresh. */
const ralphTool = defineTool<string>({
  name: 'ralph',
  description:
    'Run the objective for a bounded number of rounds, each round starting fresh with '
    + 'only the workspace as durable state. Stops early on STATUS: DONE or BLOCKED.',
  parameters: {
    objective: { type: 'string', description: 'What to keep pushing on.' },
    rounds: { type: 'number', description: 'Rounds to run, 1–10 (default 3).' },
  },
  presentCall: args => ({ card: 'generic', title: `ralph: ${oneLine(args.objective)}` }),
  output: { schema: { type: 'string' }, render: (_args, value) => [textBlock(value)] },
  async execute(args, exec) {
    const host = exec.host as ExtraHost;
    const objective = typeof args.objective === 'string' ? args.objective.trim() : '';
    if (!objective) throw new Error('objective is required');
    const rounds = typeof args.rounds === 'number' ? Math.max(1, Math.min(10, args.rounds)) : 3;
    if (!host.spawnFresh) throw new Error('ralph needs a subagent host');
    const log: string[] = [];
    for (let i = 1; i <= rounds; i++) {
      const task = [
        `Ralph round ${i}/${rounds}. Objective: ${objective}`,
        'You start fresh: no prior conversation, only the shared workspace is durable.',
        'Do the next concrete step, then end with either "STATUS: DONE" or "STATUS: CONTINUE" or "STATUS: BLOCKED: <why>".',
      ].join('\n');
      const r = await host.spawnFresh(task, `ralph-${i}`);
      const done = /STATUS:\s*DONE/i.test(r.reply);
      const blocked = /STATUS:\s*BLOCKED/i.test(r.reply);
      log.push(`round ${i} (${r.id}): ${clip(r.reply, 600)}`);
      if (done || blocked) break;
    }
    return clip(log.join('\n\n'));
  },
});

registerTool(toolSpecFrom(ralphTool, { plane: 'agent' }));

/** `stagehand_navigate` — navigate the page (alias of `browser_navigate`). */
const stagehandNavigateTool = defineTool<string>({
  name: 'stagehand_navigate',
  description: 'Navigate the session\'s browser to a URL (stagehand alias).',
  parameters: { url: { type: 'string', description: 'Absolute http(s) URL.' } },
  presentCall: args => ({ card: 'generic', title: `open ${oneLine(args.url)}` }),
  output: { schema: { type: 'string' }, render: (_args, value) => [textBlock(value)] },
  async execute(args, exec) {
    const host = exec.host as ExtraHost;
    const url = typeof args.url === 'string' ? args.url : '';
    if (!url) throw new Error('url is required');
    const page = await browserNavigate(host.sessionId, url);
    return clip(`title: ${page.title}\nurl: ${page.url}\n\n${page.text}`);
  },
});

/** `stagehand_extract` — text of the current page (alias of `browser_extract`). */
const stagehandExtractTool = defineTool<string>({
  name: 'stagehand_extract',
  description: 'Extract text from the current page (stagehand alias).',
  parameters: { selector: { type: 'string', description: 'CSS selector to narrow to.' } },
  presentCall: _args => ({ card: 'generic', title: 'extract' }),
  output: { schema: { type: 'string' }, render: (_args, value) => [textBlock(value)] },
  async execute(args, exec) {
    const host = exec.host as ExtraHost;
    return clip(await browserExtract(
      host.sessionId,
      typeof args.selector === 'string' ? args.selector : undefined,
    ));
  },
});

/** `stagehand_screenshot` — capture the page (alias of `browser_screenshot`). */
const stagehandScreenshotTool = defineTool<string>({
  name: 'stagehand_screenshot',
  description: 'Screenshot the current page (stagehand alias).',
  parameters: { path: { type: 'string', description: 'Target file.' } },
  presentCall: _args => ({ card: 'generic', title: 'screenshot' }),
  output: { schema: { type: 'string' }, render: (_args, value) => [textBlock(value)] },
  async execute(args, exec) {
    const host = exec.host as ExtraHost;
    const file = await browserScreenshot(
      host.sessionId,
      host.workspace,
      typeof args.path === 'string' ? args.path : undefined,
    );
    return `OK: screenshot -> ${file}`;
  },
});

/** `stagehand_tabs` — current page identity (single-tab mode). */
const stagehandTabsTool = defineTool<string>({
  name: 'stagehand_tabs',
  description: 'Report the current page URL and title (single-tab mode).',
  parameters: {},
  presentCall: _args => ({ card: 'generic', title: 'list tabs' }),
  output: { schema: { type: 'string' }, render: (_args, value) => [textBlock(value)] },
  async execute(_args, exec) {
    const host = exec.host as ExtraHost;
    // Ask the page, don't navigate: 'about:blank' is not http(s) and would be
    // rejected by the navigate guard.
    const href = await browserEvaluate(host.sessionId, 'location.href');
    const title = await browserEvaluate(host.sessionId, 'document.title');
    return `single-tab mode; current url: ${href}\ntitle: ${title}`;
  },
});

/** `stagehand_observe` — the interactive elements on the page. */
const stagehandObserveTool = defineTool<string>({
  name: 'stagehand_observe',
  description: 'List the page\'s interactive elements (links, buttons, inputs).',
  parameters: {},
  presentCall: _args => ({ card: 'generic', title: 'observe page' }),
  output: { schema: { type: 'string' }, render: (_args, value) => [textBlock(value)] },
  async execute(_args, exec) {
    const host = exec.host as ExtraHost;
    // No planner: report the interactive elements, which is what an observe
    // step needs to hand back to a model.
    const text = await browserExtract(host.sessionId, 'a,button,input,select,textarea');
    return clip(text || '(no interactive elements)');
  },
});

/** `stagehand_act` — click or type through a small JS shim. */
const stagehandActTool = defineTool<string>({
  name: 'stagehand_act',
  description: 'Act on the page: click a selector, or type a value into it.',
  parameters: {
    action: { type: 'string', enum: ['click', 'type'] },
    selector: { type: 'string', description: 'CSS selector to act on.' },
    value: { type: 'string', description: 'Text to type (for action=type).' },
    url: { type: 'string', description: 'Navigate first, when given.' },
  },
  presentCall: args => ({ card: 'generic', title: `act: ${oneLine(args.action)}` }),
  output: { schema: { type: 'string' }, render: (_args, value) => [textBlock(value)] },
  async execute(args, exec) {
    const host = exec.host as ExtraHost;
    const action = typeof args.action === 'string' ? args.action : '';
    const selector = typeof args.selector === 'string' ? args.selector : '';
    const value = typeof args.value === 'string' ? args.value : '';
    if (!action || !selector) throw new Error('action and selector are required');
    // Drive the page through the same browser session via a tiny JS shim.
    if (typeof args.url === 'string') await browserNavigate(host.sessionId, args.url);
    const js = action === 'click'
      ? `(() => { const el = document.querySelector(${JSON.stringify(selector)}); if (!el) return 'not found'; el.click(); return 'clicked'; })()`
      : action === 'type'
        // A form control takes `value`, anything else takes textContent; both
        // get an input event so frameworks notice either way.
        ? `(() => { const el = document.querySelector(${JSON.stringify(selector)}); if (!el) return 'not found';`
          + ` if ('value' in el) { el.value = ${JSON.stringify(value)}; } else { el.textContent = ${JSON.stringify(value)}; }`
          + ` el.dispatchEvent(new Event('input', { bubbles: true })); return 'typed'; })()`
        : null;
    if (!js) throw new Error(`unsupported action "${action}" (click|type)`);
    return await browserEvaluate(host.sessionId, js);
  },
});

registerTool(toolSpecFrom(stagehandNavigateTool, { plane: 'agent' }));
registerTool(toolSpecFrom(stagehandExtractTool, { plane: 'agent' }));
registerTool(toolSpecFrom(stagehandScreenshotTool, { plane: 'agent' }));
registerTool(toolSpecFrom(stagehandTabsTool, { plane: 'agent' }));
registerTool(toolSpecFrom(stagehandObserveTool, { plane: 'agent' }));
registerTool(toolSpecFrom(stagehandActTool, { plane: 'agent' }));

/** `plugin_manager` — list the plugins loaded in this process. */
const pluginManagerTool = defineTool<string>({
  name: 'plugin_manager',
  description: 'List the loaded plugins: name, state and the events they hook.',
  parameters: {},
  presentCall: _args => ({ card: 'generic', title: 'plugins' }),
  output: { schema: { type: 'string' }, render: (_args, value) => [textBlock(value)] },
  async execute(_args, exec) {
    const host = exec.host as ExtraHost;
    if (!host.plugins) throw new Error('plugin introspection is not available in this host');
    const list = host.plugins.list();
    return list.length
      ? list.map(p => `${p.name}\t${p.enabled ? 'enabled' : 'disabled'}\t${p.hooks.join(',')}`).join('\n')
      : '(no plugins)';
  },
});

/** `cordis_inspect_list` — Cordis name for `plugin_manager`. */
const cordisInspectListTool = defineTool<string>({
  name: 'cordis_inspect_list',
  description: 'List the loaded plugins (Cordis alias of plugin_manager).',
  parameters: {},
  presentCall: _args => ({ card: 'generic', title: 'list plugins' }),
  output: { schema: { type: 'string' }, render: (_args, value) => [textBlock(value)] },
  async execute(_args, exec) {
    const host = exec.host as ExtraHost;
    if (!host.plugins) throw new Error('plugin introspection is not available in this host');
    const list = host.plugins.list();
    return list.length
      ? list.map(p => `${p.name}\t${p.enabled ? 'enabled' : 'disabled'}\t${p.hooks.join(',')}`).join('\n')
      : '(no plugins)';
  },
});

/** `cordis_inspect_query` — one plugin's full descriptor. */
const cordisInspectQueryTool = defineTool<string>({
  name: 'cordis_inspect_query',
  description: 'Show one plugin\'s descriptor as JSON.',
  parameters: { name: { type: 'string', description: 'Plugin name.' } },
  presentCall: args => ({ card: 'generic', title: `inspect ${oneLine(args.name)}` }),
  output: { schema: { type: 'string' }, render: (_args, value) => [textBlock(value)] },
  async execute(args, exec) {
    const host = exec.host as ExtraHost;
    if (!host.plugins) throw new Error('plugin introspection is not available in this host');
    const target = typeof args.name === 'string' ? args.name : '';
    if (!target) throw new Error('name is required');
    const info = host.plugins.inspect(target);
    if (info === undefined) throw new Error(`no plugin ${target}`);
    return clip(JSON.stringify(info, null, 2));
  },
});

/** `plugin_market` — read the plugin registry (URL or local JSON). */
const pluginMarketTool = defineTool<string>({
  name: 'plugin_market',
  description: 'Read the plugin market configured by TRHA_PLUGIN_MARKET (URL or JSON file).',
  parameters: {},
  presentCall: _args => ({ card: 'generic', title: 'plugin market' }),
  output: { schema: { type: 'string' }, render: (_args, value) => [textBlock(value)] },
  async execute() {
    const source = process.env.TRHA_PLUGIN_MARKET;
    if (!source) throw new Error('plugin_market needs TRHA_PLUGIN_MARKET (URL or JSON file)');
    // A URL source is egress; a local file is not.
    if (/^https?:/i.test(source) && sandboxBlocksNetwork()) {
      throw new Error('network access is disabled by the sandbox policy (network: off).');
    }
    const raw = /^https?:/i.test(source)
      ? await (await fetch(source)).text()
      : await readFile(source, 'utf8');
    const parsed = JSON.parse(raw) as
      | Array<{ name?: string; version?: string; description?: string }>
      | { plugins?: unknown[] };
    const list = Array.isArray(parsed)
      ? parsed
      : (parsed.plugins ?? []) as Array<{ name?: string; version?: string; description?: string }>;
    return list.length
      ? clip(list.map(p => `${p.name ?? '?'}\t${p.version ?? ''}\t${p.description ?? ''}`).join('\n'))
      : '(market is empty)';
  },
});

registerTool(toolSpecFrom(pluginManagerTool, { plane: 'host' }));
registerTool(toolSpecFrom(cordisInspectListTool, { plane: 'host' }));
registerTool(toolSpecFrom(cordisInspectQueryTool, { plane: 'host' }));
registerTool(toolSpecFrom(pluginMarketTool, { plane: 'host' }));

/** `wait_agent` — block until a subagent goes idle (bounded). */
const waitAgentTool = defineTool<string>({
  name: 'wait_agent',
  description: 'Wait until a subagent goes idle, up to a bounded timeout.',
  parameters: {
    id: { type: 'string', description: 'Subagent id.' },
    timeout_ms: {
      type: 'number',
      description: 'Maximum wait in ms (default 30000, capped at 120000).',
    },
  },
  presentCall: args => ({ card: 'generic', title: `wait ${oneLine(args.id)}` }),
  output: { schema: { type: 'string' }, render: (_args, value) => [textBlock(value)] },
  async execute(args, exec) {
    const host = exec.host as ExtraHost;
    const id = typeof args.id === 'string' ? args.id : '';
    const timeout = typeof args.timeout_ms === 'number' ? args.timeout_ms : 30_000;
    if (!id) throw new Error('id is required');
    const deadline = Date.now() + Math.min(timeout, 120_000);
    while (Date.now() < deadline) {
      const ref = host.agents?.list().find(a => a.id === id);
      if (!ref) throw new Error(`no agent ${id}`);
      if (!ref.busy) return `OK: ${id} is idle (${ref.messages} msgs)`;
      await new Promise(r => setTimeout(r, 100));
    }
    return `TIMEOUT: ${id} still busy after ${timeout} ms`;
  },
});

/** `spawn_teammate` — spawn a teammate for one task and record it on the team list. */
const spawnTeammateTool = defineTool<string>({
  name: 'spawn_teammate',
  description: 'Spawn a teammate subagent for one task; it also lands on the shared team list.',
  parameters: {
    task: { type: 'string', description: 'What the teammate should do.' },
    name: { type: 'string', description: 'Teammate name (default "teammate").' },
  },
  output: { schema: { type: 'string' }, render: (_args, value) => [textBlock(value)] },
  presentCall: args => ({ card: 'generic', title: `spawn ${oneLine(args.name ?? args.task)}` }),
  async execute(args, exec) {
    const host = exec.host as ExtraHost;
    if (!host.agents) throw new Error('subagents are not available in this host');
    const task = typeof args.task === 'string' ? args.task : '';
    if (!task.trim()) throw new Error('task is required');
    const teammate = typeof args.name === 'string' ? args.name : 'teammate';
    const r = await host.agents.spawn(task, teammate);
    // A teammate is also a team-list entry, so the shared list names it.
    const tasks = host.agents.teamTasks();
    const entry: TeamTask = {
      id: `t${tasks.length + 1}`,
      subject: `teammate ${teammate}: ${task.slice(0, 60)}`,
      status: 'in_progress',
      assignee: r.id,
    };
    host.agents.setTeamTasks([...tasks, entry]);
    return `teammate ${r.id} finished:\n${clip(r.reply)}`;
  },
});

/** `list_subagent_models` — models a subagent can be spawned with. */
const listSubagentModelsTool = defineTool<string>({
  name: 'list_subagent_models',
  description: 'List the models a subagent can be spawned with.',
  parameters: {},
  presentCall: _args => ({ card: 'generic', title: 'list models' }),
  output: { schema: { type: 'string' }, render: (_args, value) => [textBlock(value)] },
  async execute(_args, exec) {
    const host = exec.host as ExtraHost;
    const models = host.models?.() ?? [];
    return models.length
      ? models.map(m => `${m.name}\t${m.description ?? ''}`).join('\n')
      : '(no models configured)';
  },
});

registerTool(toolSpecFrom(waitAgentTool, { plane: 'host' }));
registerTool(toolSpecFrom(spawnTeammateTool, { plane: 'host' }));
registerTool(toolSpecFrom(listSubagentModelsTool, { plane: 'host' }));

/** Shared execute body for `str_replace_editor` and `unified_edit`. */
async function strReplaceEditorExecute(
  args: Record<string, unknown>,
  exec: { host: unknown },
): Promise<string> {
  const host = exec.host as ExtraHost;
  const command = typeof args.command === 'string' ? args.command : 'view';
  const rawPath = typeof args.path === 'string' ? args.path : '';
  if (!rawPath) throw new Error('path is required');
  const file = path.resolve(host.cwd(), rawPath);
  // Every write below is confined exactly like `write`/`edit` (Server/toolGuard):
  // this alias used to resolve an absolute path verbatim, so `create` could write
  // anywhere on disk while the documented `write` tool would have refused it.
  const writeTarget = async (): Promise<string | null> =>
    confineWritePath(host.workspace, file, host.extraWriteRoots?.() ?? []);

  if (command === 'view') {
    try {
      const text = await readFile(file, 'utf8');
      return clip(text.split('\n').map((l, i) => `${i + 1}\t${l}`).join('\n'));
    } catch (e) {
      // viewing a directory lists it
      try {
        const entries = await readdir(file, { withFileTypes: true });
        return entries.map(e2 => `${e2.isDirectory() ? 'd' : 'f'} ${e2.name}`).join('\n');
      } catch {
        throw new Error((e as Error).message);
      }
    }
  }
  if (command === 'create') {
    const target = await writeTarget();
    if (!target) throw new Error(`path escapes the workspace: ${rawPath}`);
    const body = typeof args.file_text === 'string' ? args.file_text : '';
    await mkdir(path.dirname(target), { recursive: true });
    await writeFile(target, body, 'utf8');
    return `OK: created ${target} (${body.length} chars)`;
  }
  if (command === 'str_replace') {
    const oldStr = typeof args.old_str === 'string' ? args.old_str : '';
    const newStr = typeof args.new_str === 'string' ? args.new_str : '';
    if (!oldStr) throw new Error('old_str is required');
    const target = await writeTarget();
    if (!target) throw new Error(`path escapes the workspace: ${rawPath}`);
    let text: string;
    try {
      text = await readFile(target, 'utf8');
    } catch (e) {
      throw new Error((e as Error).message);
    }
    const count = text.split(oldStr).length - 1;
    if (count === 0) throw new Error('old_str not found');
    if (count > 1) throw new Error(`old_str appears ${count} times; make it unique`);
    await writeFile(target, text.replace(oldStr, newStr), 'utf8');
    return `OK: replaced 1 occurrence in ${target}`;
  }
  if (command === 'insert') {
    const line = typeof args.insert_line === 'number' ? args.insert_line : 0;
    const text = typeof args.new_str === 'string' ? args.new_str : '';
    const target = await writeTarget();
    if (!target) throw new Error(`path escapes the workspace: ${rawPath}`);
    let body: string;
    try {
      body = await readFile(target, 'utf8');
    } catch (e) {
      throw new Error((e as Error).message);
    }
    const lines = body.split('\n');
    const at = Math.max(0, Math.min(lines.length, line));
    lines.splice(at, 0, ...text.split('\n'));
    await writeFile(target, lines.join('\n'), 'utf8');
    return `OK: inserted ${text.split('\n').length} line(s) at ${at + 1}`;
  }
  throw new Error(`unknown command "${command}" (view|create|str_replace|insert)`);
}

const EDITOR_PARAMETERS = {
  command: { type: 'string', enum: ['view', 'create', 'str_replace', 'insert'] },
  path: { type: 'string', description: 'File path, absolute or relative to cwd.' },
  file_text: { type: 'string', description: 'Body for command=create.' },
  old_str: { type: 'string', description: 'Snippet to replace (must be unique).' },
  new_str: { type: 'string', description: 'Replacement text, or text to insert.' },
  insert_line: { type: 'number', description: 'Zero-based line to insert at.' },
};

/** `str_replace_editor` — view / create / replace / insert on one file. */
const strReplaceEditorTool = defineTool<string>({
  name: 'str_replace_editor',
  description:
    'Edit one file: view it, create it, replace a unique snippet, or insert lines. '
    + 'Writes are confined to the workspace exactly like `write` / `edit`.',
  parameters: EDITOR_PARAMETERS,
  presentCall: args => ({ card: 'diff', title: `edit ${oneLine(args.path)}`, rawInput: args.path }),
  output: { schema: { type: 'string' }, render: (_args, value) => [textBlock(value)] },
  execute: strReplaceEditorExecute,
});

/** `unified_edit` — same implementation, alternate name. */
const unifiedEditTool = defineTool<string>({
  name: 'unified_edit',
  description: 'Edit one file (alias of str_replace_editor): view, create, str_replace, insert.',
  parameters: EDITOR_PARAMETERS,
  presentCall: args => ({ card: 'diff', title: `edit ${oneLine(args.path)}`, rawInput: args.path }),
  output: { schema: { type: 'string' }, render: (_args, value) => [textBlock(value)] },
  execute: strReplaceEditorExecute,
});

registerTool(toolSpecFrom(strReplaceEditorTool, { plane: 'agent' }));
registerTool(toolSpecFrom(unifiedEditTool, { plane: 'agent' }));

/** `create_worktree` — add a git worktree and a new branch. */
const createWorktreeTool = defineTool<string>({
  name: 'create_worktree',
  description: 'Create a git worktree at a path, on a new branch.',
  parameters: {
    path: { type: 'string', description: 'Worktree path, relative to the cwd.' },
    branch: { type: 'string', description: 'Branch name (default wt-<timestamp>).' },
  },
  presentCall: args => ({ card: 'generic', title: `worktree ${oneLine(args.branch ?? args.name)}` }),
  output: { schema: { type: 'string' }, render: (_args, value) => [textBlock(value)] },
  async execute(args, exec) {
    const host = exec.host as ExtraHost;
    const target = typeof args.path === 'string' ? args.path : '';
    const branch = typeof args.branch === 'string'
      ? args.branch
      : `wt-${Date.now().toString(36)}`;
    if (!target) throw new Error('path is required');
    const r = await sh(
      host,
      `git worktree add ${JSON.stringify(path.resolve(host.cwd(), target))} -b ${JSON.stringify(branch)}`,
    );
    if (r.code !== 0) throw new Error(clip(r.out));
    return `OK: worktree at ${target} on ${branch}\n${clip(r.out)}`;
  },
});

/** `load_workspace_dependencies` — install the cwd's dependency manifest. */
const loadWorkspaceDependenciesTool = defineTool<string>({
  name: 'load_workspace_dependencies',
  description: 'Install the working directory\'s dependencies by detecting its manifest.',
  parameters: {},
  presentCall: _args => ({ card: 'generic', title: 'load dependencies' }),
  output: { schema: { type: 'string' }, render: (_args, value) => [textBlock(value)] },
  async execute(_args, exec) {
    const host = exec.host as ExtraHost;
    const dir = host.cwd();
    const has = async (f: string): Promise<boolean> => {
      try {
        await stat(path.join(dir, f));
        return true;
      } catch {
        return false;
      }
    };
    let cmd = '';
    if (await has('pnpm-lock.yaml')) cmd = 'pnpm install';
    else if (await has('package-lock.json') || await has('package.json')) cmd = 'npm install';
    else if (await has('Cargo.toml')) cmd = 'cargo fetch';
    else if (await has('stack.yaml')) cmd = 'stack build --only-dependencies';
    else if (await has('cabal.project')) cmd = 'cabal build --only-dependencies';
    else throw new Error('no recognised dependency manifest in the working directory');
    const r = await sh(host, cmd);
    return clip(`$ ${cmd}\nexit ${r.code}\n${r.out}`);
  },
});

registerTool(toolSpecFrom(createWorktreeTool, { plane: 'agent' }));
registerTool(toolSpecFrom(loadWorkspaceDependenciesTool, { plane: 'agent' }));

/** `web_search` — SearXNG first, then the Bing / DuckDuckGo HTML backends. */
const webSearchTool = defineTool<string>({
  name: 'web_search',
  description:
    'Search the web. Uses TRHA_SEARX_URL (a SearXNG instance in JSON mode) when set, '
    + 'otherwise the Bing and DuckDuckGo HTML backends. Subject to the sandbox network '
    + 'policy: with `network: off` the search is refused outright.',
  parameters: {
    query: { type: 'string', description: 'Search terms.' },
  },
  presentCall: args => ({ card: 'generic', title: `search ${oneLine(args.query)}`, rawInput: args.query }),
  // DSH's `tool-web/search` presents a result card; the distilled fact is how
  // many rows came back.
  presentResult: (_args, result) => {
    const blocks = String(result ?? '').split('\n\n').filter(b => b.trim() !== '').length;
    return { card: 'generic' as const, title: `${blocks} result${blocks === 1 ? '' : 's'}` };
  },
  output: { schema: { type: 'string' }, render: (_args, value) => [textBlock(value)] },
  timeoutMs: 60_000,
  async execute(args) {
    // Same reason as `web_fetch`: this runs `fetch` in the scheduler process,
    // so `network: off` (which only unsets the child's netns) would not stop it.
    if (sandboxBlocksNetwork()) {
      throw new Error(
        'network access is disabled by the sandbox policy (network: off). '
        + 'Enable it under /sandbox, or run outside the sandbox.',
      );
    }
    const query = typeof args.query === 'string' ? args.query.trim() : '';
    if (!query) throw new Error('query is required');
    const searx = process.env.TRHA_SEARX_URL;
    const ua = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36';
    const strip = (s: string): string =>
      s.replace(/<[^>]+>/g, ' ')
        .replace(/&amp;/g, '&').replace(/&quot;/g, '"').replace(/&#x27;/g, "'")
        .replace(/\s+/g, ' ').trim();
    const fromBing = (html: string): string[] => {
      const out: string[] = [];
      const re = /<li class="b_algo"[\s\S]*?<h2[^>]*>\s*<a[^>]*href="([^"]+)"[^>]*>([\s\S]*?)<\/a>[\s\S]*?(?:<p[^>]*>([\s\S]*?)<\/p>)?/gi;
      let m: RegExpExecArray | null;
      while ((m = re.exec(html)) && out.length < 10) {
        out.push(`${strip(m[2] ?? '')}\n${m[1] ?? ''}\n${strip(m[3] ?? '').slice(0, 200)}`);
      }
      return out;
    };
    const fromDdg = (html: string): string[] => {
      const out: string[] = [];
      const re = /<a[^>]*class="result__a"[^>]*href="([^"]+)"[^>]*>([\s\S]*?)<\/a>/gi;
      let m: RegExpExecArray | null;
      while ((m = re.exec(html)) && out.length < 10) {
        out.push(`${strip(m[2] ?? '')}\n${m[1] ?? ''}`);
      }
      return out;
    };
    if (searx) {
      try {
        const url = `${searx.replace(/\/$/, '')}/search?q=${encodeURIComponent(query)}&format=json`;
        const res = await fetch(url, { headers: { 'User-Agent': ua } });
        const body = await res.text();
        if (res.ok) {
          const data = JSON.parse(body) as {
            results?: Array<{ title?: string; url?: string; content?: string }>;
          };
          const rows = (data.results ?? []).slice(0, 10)
            .map(r => `${r.title ?? ''}\n${r.url ?? ''}\n${(r.content ?? '').slice(0, 200)}`);
          if (rows.length) return clip(rows.join('\n\n'));
        }
      } catch { /* fall through to the HTML backends */ }
    }
    // DuckDuckGo now answers machine traffic with a 202 challenge page, so Bing
    // is the primary HTML fallback. Both must return a real 200 with parsed
    // rows; a challenge page is never reported as a result.
    const backends: Array<{ name: string; url: string; parse: (h: string) => string[] }> = [
      { name: 'bing', url: `https://www.bing.com/search?q=${encodeURIComponent(query)}`, parse: fromBing },
      { name: 'duckduckgo', url: `https://html.duckduckgo.com/html/?q=${encodeURIComponent(query)}`, parse: fromDdg },
    ];
    for (const b of backends) {
      try {
        const res = await fetch(b.url, {
          headers: { 'User-Agent': ua, 'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8' },
        });
        const body = await res.text();
        if (!res.ok) continue; // 202 = DuckDuckGo challenge, 403 = blocked
        const rows = b.parse(body);
        if (rows.length) return clip(rows.join('\n\n'));
      } catch { /* try the next backend */ }
    }
    throw new Error(
      `no search backend answered for "${query}" — set TRHA_SEARX_URL to a SearXNG `
      + 'instance (json format), or check the network/proxy',
    );
  },
});

registerTool(toolSpecFrom(webSearchTool, { plane: 'agent' }));

/** `pwsh` — run a PowerShell command (Windows-only). */
const pwshTool = defineTool<string>({
  name: 'pwsh',
  description:
    'Run a PowerShell command. Windows-only: off Windows this fails with an explanatory '
    + 'error, use run_code (bash/python/node) instead.',
  parameters: {
    command: { type: 'string', description: 'The PowerShell command.' },
  },
  presentCall: args => ({ card: 'terminal', title: oneLine(args.command), rawInput: args.command }),
  output: { schema: { type: 'string' }, render: (_args, value) => [textBlock(value)] },
  timeoutMs: 120_000,
  async execute(args, exec) {
    const host = exec.host as ExtraHost;
    const cmd = typeof args.command === 'string' ? args.command : '';
    if (!cmd) throw new Error('command is required');
    // PS7 (pwsh) first; Windows PowerShell 5 (powershell.exe) as the win32 fallback.
    let r: { code: number; out: string } = { code: 127, out: '' };
    for (const exe of powerShellCandidates()) {
      // T1.6 execution point #5: never spawn unconfined once the seam is on.
      // Windows has no backend yet (ADR-007), so this fails closed with
      // SandboxUnavailable instead of silently running outside the boundary.
      if (sandboxEnabled()) {
        try {
          const res = await sandboxedSpawn(defaultSandboxScope(host.cwd()), {
            argv: [exe, '-NoLogo', '-Command', cmd],
            cwd: host.cwd(),
          });
          return clip(`exit ${res.code ?? -1}\n${res.stdout}${res.stderr}`);
        } catch (e) {
          throw new Error(`sandbox unavailable for pwsh: ${(e as Error).message}`);
        }
      }
      r = await new Promise<{ code: number; out: string }>(resolve => {
        const child = spawn(exe, ['-NoLogo', '-Command', cmd], {
          cwd: host.cwd(),
          env: hardenedEnv(),
        });
        const out: string[] = [];
        child.stdout.on('data', (b: Buffer) => out.push(b.toString('utf8')));
        child.stderr.on('data', (b: Buffer) => out.push(b.toString('utf8')));
        child.on('error', e => resolve({ code: 127, out: e.message }));
        child.on('exit', code => resolve({ code: code ?? -1, out: out.join('') }));
      });
      if (r.code !== 127) break; // executable missing -> try the next candidate
    }
    if (r.code === 127) {
      // Keep the historical "neither pwsh nor powershell.exe is installed"
      // wording (tests and docs key on it) but say which candidates were tried
      // and, off Windows, that no candidate can exist at all.
      const note = process.platform === 'win32'
        ? ''
        : ' — PowerShell is Windows-only; use run_code (bash/python/node) here';
      throw new Error(
        `neither pwsh nor powershell.exe is installed `
        + `(tried ${powerShellCandidates().join(' / ')})${note}: ${r.out}`,
      );
    }
    return clip(`exit ${r.code}\n${r.out}`);
  },
});

registerTool(toolSpecFrom(pwshTool, { plane: 'agent' }));
