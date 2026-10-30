// Standard tools ported from deepseek-harness's `standard` agent preset:
// todo, goal, schedule, background jobs, skills and web fetch.
//
// Deliberately excluded (needs something trha does not have): subagent/team/
// workflow tools (no multi-agent runtime), `present` (a UI channel), and
// `ask_user_question` (needs a free-text answer channel — the approval gate is
// yes/no). `exit_plan_mode` is covered by the kernel's plan approval instead of
// a second, competing mechanism.
//
// State split:
//   * todos / goal / schedules belong to the session and are persisted with it;
//   * jobs are process-local (a child process cannot outlive its parent) and are
//     reported as such rather than pretending to survive a restart.

import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import { appendFile, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { discoverSkills, readSkill, skillDirs } from './skills.js';
import { listMcpResources, listMcpResourceTemplates, readMcpResource } from './mcp.js';
import { hardenedEnv, resolveShell, shellRunner } from './shell.js';
import { defaultSandboxScope, sandboxBlocksNetwork, sandboxEnabled, sandboxedSpawn } from './sandbox.js';
import { registerTool, renderToolValue, resolveTool } from './toolRegistry.js';
import { defineTool, oneLine, textBlock, toolSpecFrom } from './toolSchema.js';
import { editDiff, globToRegExp, resolveReadPath, walkFiles, workspaceRelative } from './fsWalk.js';
import { confineWritePath, limitOutput } from './toolGuard.js';
import { runShell } from './shellRun.js';
import { snapshotFile } from './fileHistory.js';
import { lspQuery, type LspOperation } from './lsp.js';
import { browserClose, browserExtract, browserNavigate, browserScreenshot } from './browser.js';

export interface Todo {
  id: string;
  text: string;
  status: 'pending' | 'in_progress' | 'completed';
}

export interface Goal {
  objective: string;
  status: 'active' | 'paused' | 'complete';
  budget?: number | undefined;
  createdAt: string;
}

export interface Schedule {
  id: string;
  prompt: string;
  at: string;            // ISO timestamp of the next firing
  repeatMs?: number | undefined;
  status: 'active' | 'cancelled' | 'fired' | 'missed';
  runs?: number;
  lastFiredAt?: string;
}

export interface JobRecord {
  id: string;
  command: string;
  startedAt: number;
  output: string[];
  status: 'running' | 'exited';
  exitCode?: number;
  child?: ChildProcessWithoutNullStreams | undefined;
}

export interface PendingQuestion {
  id: string;
  question: string;
  options?: string[];
  askedAt: string;
}

export interface AgentRef {
  id: string;
  parentId?: string;
  busy?: boolean;
  messages: number;
  mode?: string;
}

export interface TeamTask {
  id: string;
  subject: string;
  description?: string;
  status: 'pending' | 'in_progress' | 'completed';
  assignee?: string;
}

/** Host hooks the agent-orchestration tools need; supplied by the scheduler. */
export interface AgentHooks {
  spawn: (task: string, name?: string, agent?: string) => Promise<{ id: string; reply: string }>;
  list: () => AgentRef[];
  send: (id: string, text: string) => Promise<{ delivered: boolean; reply?: string }>;
  interrupt: (id: string) => boolean;
  /** Team tasks live on the root session so every teammate sees them. */
  teamTasks: () => TeamTask[];
  setTeamTasks: (tasks: TeamTask[]) => void;
}

export interface StandardToolHost {
  workspace: string;
  agents?: AgentHooks;
  /** Mutable session slice; the caller persists it after the tool runs. */
  state: {
    todos?: Todo[];
    goal?: Goal | null;
    schedules?: Schedule[];
    pendingQuestion?: PendingQuestion | null;
  };
  /** Jobs are shared per scheduler process, keyed by session. */
  jobs: Map<string, JobRecord>;
  sessionId: string;
  /**
   * The session's current directory. May differ from `workspace` after `cd`;
   * the core file tools (`glob`/`grep`/`read`/`write`) resolve against it.
   * Named `sessionCwd` because `ExtraHost.cwd` is a getter function.
   */
  sessionCwd?: string;
  /** Extra roots the user allowed for writes (GET/PUT /api/extra-roots). */
  writeRoots?: string[];
  now?: () => Date;
}

const MAX_OUTPUT_CHARS = 20_000;
const MAX_JOB_OUTPUT = 200_000;

const clip = (s: string, cap = MAX_OUTPUT_CHARS): string =>
  s.length <= cap ? s : `${s.slice(0, cap)}\n…(${s.length - cap} more chars)`;

/** Order-insensitive id/text/status comparison (a rewrite must mean something). */
function sameTodos(a: readonly Todo[], b: readonly Todo[]): boolean {
  if (a.length !== b.length) return false;
  const key = (t: Todo): string => `${t.text}\u0000${t.status}`;
  const left = a.map(key).sort();
  const right = b.map(key).sort();
  return left.every((k, i) => k === right[i]);
}

export const STANDARD_TOOL_NAMES = [
  'ask_user_question', 'exit_plan_mode', 'present', 'run_code', 'read_image',
  'subagent', 'list_agents', 'send_message', 'interrupt_agent',
  'team_task_create', 'team_task_list', 'team_task_update', 'workflow',
  'list_mcp_resources', 'read_mcp_resource', 'list_mcp_resource_templates', 'lsp',
  'browser_navigate', 'browser_extract', 'browser_screenshot', 'browser_close',
  'todo_write',
  'create_goal', 'get_goal', 'update_goal',
  'schedule_create', 'schedule_list', 'schedule_update', 'schedule_delete',
  'job_list', 'job_output', 'job_kill',
  'skill', 'web_fetch',
] as const;

export function isStandardTool(name: string): boolean {
  return (STANDARD_TOOL_NAMES as readonly string[]).includes(name);
}

/** Start a background command; returns immediately with the job id. */
export function startJob(host: StandardToolHost, command: string): string {
  // Stable, predictable ids: the model reads them back in job_output/job_kill.
  const id = `job-${host.jobs.size + 1}`;
  const sh = resolveShell(command);
  // Sandboxed jobs run one-shot through the runner: the id is returned
  // immediately and the captured output lands when the command finishes.
  if (sandboxEnabled()) {
    const record: JobRecord = {
      id, command, startedAt: Date.now(), output: [], status: 'running',
    };
    host.jobs.set(id, record);
    void (async () => {
      try {
        const r = await sandboxedSpawn(defaultSandboxScope(host.workspace), {
          argv: [sh.cmd, ...sh.args],
          cwd: host.workspace,
          timeoutMs: 600_000,
        });
        record.output.push(r.stdout + r.stderr);
        record.exitCode = r.code ?? -1;
      } catch (e) {
        record.output.push(`ERROR: ${(e as Error).message}`);
        record.exitCode = 1;
      } finally {
        record.status = 'exited';
      }
    })();
    return id;
  }
  const child = spawn(sh.cmd, sh.args, { cwd: host.workspace, ...sh.options, env: hardenedEnv() }) as ChildProcessWithoutNullStreams;
  const record: JobRecord = { id, command, startedAt: Date.now(), output: [], status: 'running', child };
  const push = (chunk: Buffer): void => {
    record.output.push(chunk.toString('utf8'));
    const total = record.output.join('').length;
    if (total > MAX_JOB_OUTPUT) record.output = [record.output.join('').slice(-MAX_JOB_OUTPUT)];
  };
  child.stdout.on('data', push);
  child.stderr.on('data', push);
  child.on('exit', code => {
    record.status = 'exited';
    record.exitCode = code ?? -1;
    record.child = undefined;
  });
  host.jobs.set(id, record);
  return id;
}

const stripHtml = (html: string): string => html
  .replace(/<script[\s\S]*?<\/script>/gi, ' ')
  .replace(/<style[\s\S]*?<\/style>/gi, ' ')
  .replace(/<noscript[\s\S]*?<\/noscript>/gi, ' ')
  .replace(/<!--[\s\S]*?-->/g, ' ')
  .replace(/<\/(p|div|li|tr|h[1-6]|br|title)>/gi, '\n')
  .replace(/<br\s*\/?>/gi, '\n')
  .replace(/<[^>]+>/g, ' ')
  .replace(/&#x([0-9a-f]+);/gi, (_, h: string) => String.fromCodePoint(parseInt(h, 16)))
  .replace(/&#(\d+);/g, (_, d: string) => String.fromCodePoint(Number(d)))
  .replace(/&nbsp;/g, ' ')
  .replace(/&quot;/g, '"')
  .replace(/&apos;/g, "'")
  .replace(/&lt;/g, '<')
  .replace(/&gt;/g, '>')
  .replace(/&amp;/g, '&')
  .replace(/&mdash;/g, '—')
  .replace(/&ndash;/g, '–')
  .replace(/&hellip;/g, '…')
  .replace(/[ \t]+/g, ' ')
  .replace(/\n{3,}/g, '\n\n')
  .trim();

/** Run one standard tool. Returns null when the name is not one of them. */
export async function runStandardTool(
  name: string,
  args: Record<string, unknown>,
  host: StandardToolHost,
  // Optional sink for the canonical value; the turn loop uses it to feed
  // `presentResult`. Callers that only want text can omit it.
  out?: { value?: unknown; meta?: unknown },
): Promise<string | null> {
  // Registered tools take precedence over the legacy chain, so migration is
  // one tool at a time: anything not yet registered still runs below.
  const registered = resolveTool(name);
  if (registered?.handler) {
    const rendered = await renderToolValue(registered, args, host);
    if (out) { out.value = rendered.value; if (rendered.meta !== undefined) out.meta = rendered.meta; }
    return rendered.text;
  }


  if (name === 'list_mcp_resources') {
    // Migrated to the registry (full DSH contract); `resolveTool` wins for this
    // name, so the chain never reaches here.
  }

  if (name === 'list_mcp_resource_templates') {
    // Migrated to the registry (full DSH contract).
  }

  if (name === 'read_mcp_resource') {
    // Migrated to the registry (full DSH contract).
  }

  if (name === 'browser_navigate') {
    // Migrated to the registry (full DSH contract); `resolveTool` wins for this name.
  }
  if (name === 'browser_extract') {
    // Migrated to the registry (full DSH contract); `resolveTool` wins for this name.
  }
  if (name === 'browser_screenshot') {
    // Migrated to the registry (full DSH contract); `resolveTool` wins for this name.
  }
  if (name === 'browser_close') {
    // Migrated to the registry (full DSH contract); `resolveTool` wins for this name.
  }

  if (name === 'lsp') {
    // Migrated to the registry (full DSH contract); `resolveTool` wins for this
    // name, so the chain never reaches here.
  }

  if (name === 'subagent') {
    // Migrated to the registry (full DSH contract); `resolveTool` wins for this
    // name, so the chain never reaches here.
  }

  if (name === 'list_agents' || name === 'send_message' || name === 'interrupt_agent') {
    // Migrated to the registry (full DSH contract): three separate tools now.
  }

  if (name === 'team_task_create') {
    // Migrated to the registry (full DSH contract); `resolveTool` wins for this
    // name, so the chain never reaches here.
  }

  if (name === 'team_task_list') {
    // Migrated to the registry (full DSH contract).
  }

  if (name === 'team_task_update') {
    // Migrated to the registry (full DSH contract).
  }

  if (name === 'workflow') {
    // Migrated to the registry (full DSH contract).
  }

  if (name === 'ask_user_question') {
    // Migrated to the registry (full DSH contract); `resolveTool` wins for this
    // name, so the chain never reaches here.
  }

  if (name === 'exit_plan_mode') {
    // Migrated to the registry (full DSH contract); `resolveTool` wins for this
    // name, so the chain never reaches here.
  }



  if (name === 'run_code') {
    // Migrated to the registry (full DSH contract); `resolveTool` wins for this
    // name, so the chain never reaches here.
  }

  if (name === 'read_image') {
    // Migrated to the registry (full DSH contract); `resolveTool` wins for this
    // name, so the chain never reaches here.
  }

  if (name === 'todo_write') {
    // Migrated to the registry (full DSH contract); `resolveTool` wins for this
    // name, so the chain never reaches here.
  }

  if (name === 'create_goal') {
    // Migrated to the registry (full DSH contract); `resolveTool` wins for this
    // name, so the chain never reaches here.
  }

  if (name === 'get_goal') {
    // Migrated to the registry (full DSH contract).
  }

  if (name === 'update_goal') {
    // Migrated to the registry (full DSH contract).
  }

  if (name === 'schedule_create') {
    // Migrated to the registry (full DSH contract); `resolveTool` wins for this
    // name, so the chain never reaches here.
  }

  if (name === 'schedule_list') {
    // Migrated to the registry (full DSH contract).
  }

  if (name === 'schedule_update') {
    // Migrated to the registry (full DSH contract).
  }

  if (name === 'schedule_delete') {
    // Migrated to the registry (full DSH contract).
  }




  if (name === 'skill') {
    // Migrated to the registry (full DSH contract); `resolveTool` wins for this
    // name, so the chain never reaches here.
  }

  if (name === 'web_fetch') {
    // Migrated to the registry (full DSH contract); `resolveTool` wins for this
    // name, so the chain never reaches here.
  }

  return null;
}

/** Persist a skill file (used by the skills round-trip test and by tooling). */
export async function writeSkill(dir: string, name: string, body: string): Promise<void> {
  await mkdir(dir, { recursive: true });
  await writeFile(path.join(dir, `${name}.md`), body, 'utf8');
}

// ── registered plugins ──────────────────────────────────────────────
//
// Step 1 of the tool-plugin migration: these names resolve from `toolRegistry`
// before the legacy chain runs. Everything not migrated still lives in the
// chain, so the rewrite can proceed one tool at a time.

/** `web_fetch` — HTTP GET with the sandbox network policy applied. */
/** `web_fetch` — HTTP GET with the sandbox network policy applied. */
const webFetchTool = defineTool<{ status: number; type: string; text: string }>({
  name: 'web_fetch',
  description:
    'Fetch an http(s) URL and return its body as text (HTML is stripped to '
    + 'readable form). Subject to the sandbox network policy: with `network: off` '
    + 'the fetch is refused outright.',
  parameters: {
    url: { type: 'string', description: 'http(s) URL to fetch.' },
  },
  output: {
    schema: {
      type: 'object',
      additionalProperties: false,
      properties: {
        status: { type: 'number' },
        type: { type: 'string' },
        text: { type: 'string' },
      },
    },
    render: (_args, value) => [textBlock(`HTTP ${value.status} ${value.type}\n${value.text}`)],
  },
  presentCall: args => ({ card: 'generic', title: `fetch ${oneLine(args.url)}`, rawInput: args.url }),
  // Read-only, no shared mutable state — same marking DSH uses.
  isConcurrencySafe: () => true,
  // DSH's `tool-web/fetch` presents a result card; the status code is what a
  // reader wants from one line.
  presentResult: (_args, result) => {
    // `web_fetch` already returns `{ status, type, text }`; read the field
    // instead of re-parsing the rendered line.
    const v = result as { status?: number };
    return {
      card: 'generic' as const,
      title: v?.status !== undefined ? `HTTP ${v.status}` : 'fetched',
    };
  },
  timeoutMs: 20_000,
  async execute(args) {
    // `network: off` must mean *no egress*, not "no egress from subprocesses":
    // this tool runs `fetch` in the scheduler process, so without this guard an
    // agent answers "network off" with a plain HTTP GET.
    if (sandboxBlocksNetwork()) {
      throw new Error(
        'network access is disabled by the sandbox policy (network: off). '
        + 'Enable it under /sandbox, or run outside the sandbox.',
      );
    }
    const url = args.url;
    if (typeof url !== 'string' || !/^https?:\/\//i.test(url)) {
      throw new Error('url must be http(s)');
    }
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), 15_000);
    try {
      const res = await fetch(url, {
        signal: ctrl.signal,
        redirect: 'follow',
        headers: {
          // Many sites answer a bare bot UA with a challenge page; a normal
          // browser UA plus language negotiation gets the readable HTML.
          'User-Agent': 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36',
          'Accept': 'text/html,application/xhtml+xml,application/json,text/plain;q=0.9,*/*;q=0.8',
          'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
        },
      });
      const type = res.headers.get('content-type') ?? '';
      const body = await res.text();
      const text = type.includes('html') ? stripHtml(body) : body;
      return { status: res.status, type, text: clip(text) };
    } finally {
      clearTimeout(timer);
    }
  },
});

registerTool(toolSpecFrom(webFetchTool, { plane: 'agent' }));

/** `present` — surface a title/body block to the UI. */
const presentTool = defineTool<{ title: string; body: string }>({
  name: 'present',
  description:
    'Show a titled block to the user. Use it for a summary or a decision point '
    + 'that deserves its own card rather than a chat paragraph.',
  parameters: {
    title: { type: 'string', description: 'Short heading.' },
    body: { type: 'string', description: 'Body text or markdown.' },
  },
  presentCall: args => ({ card: 'generic', title: `present ${oneLine(args.title)}` }),
  output: {
    schema: {
      type: 'object',
      additionalProperties: false,
      properties: { title: { type: 'string' }, body: { type: 'string' } },
    },
    render: (_args, value) => [textBlock(`PRESENT: ${JSON.stringify(value)}`)],
  },
  async execute(args) {
    const title = typeof args.title === 'string' ? args.title : '';
    const body = typeof args.body === 'string' ? args.body : '';
    if (!title && !body) throw new Error('title or body is required');
    return { title, body };
  },
});

registerTool(toolSpecFrom(presentTool, { plane: 'agent' }));

/** `job_list` — background jobs owned by this host. */
const jobListTool = defineTool<string>({
  name: 'job_list',
  description: 'List this session\'s background jobs: id, status and command.',
  parameters: {},
  presentCall: _args => ({ card: 'generic', title: 'list jobs' }),
  output: { schema: { type: 'string' }, render: (_args, value) => [textBlock(value)] },
  async execute(_args, exec) {
    const host = exec.host as StandardToolHost;
    const list = [...host.jobs.values()];
    if (list.length === 0) return '(no jobs)';
    return list.map(j =>
      `${j.id}\t${j.status}${j.exitCode !== undefined ? ` (${j.exitCode})` : ''}\t${j.command.slice(0, 80)}`,
    ).join('\n');
  },
});

/** `job_output` — collected stdout/stderr of one background job. */
const jobOutputTool = defineTool<string>({
  name: 'job_output',
  description: 'Read the collected output of one background job.',
  parameters: { id: { type: 'string', description: 'Job id returned by job_list.' } },
  presentCall: args => ({ card: 'generic', title: `job output ${oneLine(args.id)}` }),
  output: { schema: { type: 'string' }, render: (_args, value) => [textBlock(value)] },
  async execute(args, exec) {
    const host = exec.host as StandardToolHost;
    const id = typeof args.id === 'string' ? args.id : '';
    const job = host.jobs.get(id);
    if (!job) throw new Error(`no job ${id}`);
    const out = job.output.join('');
    return `status: ${job.status}${job.exitCode !== undefined ? ` exit=${job.exitCode}` : ''}\n`
      + clip(out || '(no output yet)');
  },
});

/** `job_kill` — SIGTERM one background job. */
const jobKillTool = defineTool<string>({
  name: 'job_kill',
  description: 'Stop one background job with SIGTERM.',
  parameters: { id: { type: 'string', description: 'Job id returned by job_list.' } },
  presentCall: args => ({ card: 'generic', title: `kill job ${oneLine(args.id)}` }),
  output: { schema: { type: 'string' }, render: (_args, value) => [textBlock(value)] },
  async execute(args, exec) {
    const host = exec.host as StandardToolHost;
    const id = typeof args.id === 'string' ? args.id : '';
    const job = host.jobs.get(id);
    if (!job) throw new Error(`no job ${id}`);
    if (job.status !== 'running') return `OK: ${id} already exited`;
    job.child?.kill('SIGTERM');
    job.status = 'exited';
    return `OK: killed ${id}`;
  },
});

registerTool(toolSpecFrom(jobListTool, { plane: 'host' }));
registerTool(toolSpecFrom(jobOutputTool, { plane: 'host' }));
registerTool(toolSpecFrom(jobKillTool, { plane: 'host' }));

/** `skill` — list available skills, or load one by name. */
const skillTool = defineTool<string>({
  name: 'skill',
  description:
    'List the available skills, or load one by name. Call with no name to list '
    + 'them; call with a name to read that skill\'s instructions.',
  parameters: {
    name: { type: 'string', description: 'Skill name. Omit to list every skill.' },
  },
  presentCall: args => ({ card: 'generic', title: `skill ${oneLine(args.name)}` }),
  output: { schema: { type: 'string' }, render: (_args, value) => [textBlock(value)] },
  async execute(args, exec) {
    const host = exec.host as StandardToolHost;
    const wanted = typeof args.name === 'string' ? args.name.trim() : '';
    const dirs = skillDirs(host.workspace);
    if (!wanted) {
      const skills = await discoverSkills(dirs);
      if (skills.length === 0) return `(no skills; looked in ${dirs.join(', ')})`;
      return skills
        .map(s => (s.description ? `${s.name} — ${s.description}` : s.name))
        .join('\n');
    }
    const body = await readSkill(dirs, wanted);
    if (body === null) throw new Error(`no skill "${wanted}" in ${dirs.join(', ')}`);
    return clip(body);
  },
});

registerTool(toolSpecFrom(skillTool, { plane: 'agent' }));

/** `todo_write` — replace the session's todo list. */
const todoWriteTool = defineTool<string>({
  name: 'todo_write',
  description:
    'Replace the todo list. Every item needs text and a status '
    + '(pending | in_progress | completed). Writing an identical list is a no-op '
    + 'and answers UNCHANGED.',
  parameters: {
    todos: {
      type: 'array',
      description: 'The complete list; it replaces the previous one.',
      items: {
        type: 'object',
        properties: {
          id: { type: 'string', description: 'Stable id; defaults to the 1-based index.' },
          text: { type: 'string', description: 'What the item is.' },
          status: { type: 'string', enum: ['pending', 'in_progress', 'completed'] },
        },
      },
    },
  },
  output: { schema: { type: 'string' }, render: (_args, value) => [textBlock(value)] },
  presentCall: _args => ({ card: 'generic', title: 'update todo list' }),
  async execute(args, exec) {
    const host = exec.host as StandardToolHost;
    const raw = args.todos;
    if (!Array.isArray(raw)) throw new Error('todos must be an array');
    const todos: Todo[] = raw.map((t, i) => {
      const o = t as { id?: unknown; text?: unknown; status?: unknown; content?: unknown };
      const status = typeof o.status === 'string' ? o.status : 'pending';
      return {
        id: typeof o.id === 'string' ? o.id : String(i + 1),
        text: String(o.text ?? o.content ?? ''),
        status: (['pending', 'in_progress', 'completed'].includes(status)
          ? status : 'pending') as Todo['status'],
      };
    });
    // A write that changes nothing is noise: no state change, no persist, and a
    // result that tells the model not to ask again.
    if (sameTodos(host.state.todos ?? [], todos)) {
      return `UNCHANGED: ${todos.length} todos (the list is identical; nothing was written)`;
    }
    host.state.todos = todos;
    const lines = todos.map(t =>
      `- [${t.status === 'completed' ? 'x' : t.status === 'in_progress' ? '~' : ' '}] ${t.text}`);
    return `OK: ${todos.length} todos\n${lines.join('\n')}`;
  },
});

registerTool(toolSpecFrom(todoWriteTool, { plane: 'agent' }));

/** `read_image` — inline an image file as a data URL. */
const readImageTool = defineTool<string>({
  name: 'read_image',
  description:
    'Read an image file and return it as a base64 data URL the model can see. '
    + 'Capped at 2 MiB; png, jpeg, gif and webp are recognised.',
  parameters: {
    path: { type: 'string', description: 'Image path: absolute, or relative to the workspace.' },
  },
  presentCall: args => ({ card: 'generic', title: `image ${oneLine(args.path)}` }),
  // Read-only, no shared mutable state — same marking DSH uses.
  isConcurrencySafe: () => true,
  output: { schema: { type: 'string' }, render: (_args, value) => [textBlock(value)] },
  async execute(args, exec) {
    const host = exec.host as StandardToolHost;
    const raw = args.path;
    if (typeof raw !== 'string' || !raw.trim()) throw new Error('path is required');
    const file = path.isAbsolute(raw) ? raw : path.join(host.workspace, raw);
    let buf;
    try {
      buf = await readFile(file);
    } catch (error) {
      throw new Error((error as Error).message);
    }
    if (buf.byteLength > 2 * 1024 * 1024) {
      throw new Error(`image is ${buf.byteLength} bytes; the cap is 2 MiB`);
    }
    const ext = path.extname(file).toLowerCase();
    const mime = ext === '.png' ? 'image/png'
      : ext === '.jpg' || ext === '.jpeg' ? 'image/jpeg'
      : ext === '.gif' ? 'image/gif'
      : ext === '.webp' ? 'image/webp' : 'application/octet-stream';
    return `data:${mime};base64,${buf.toString('base64')}`;
  },
});

registerTool(toolSpecFrom(readImageTool, { plane: 'agent' }));

/** `exit_plan_mode` — hand a plan to the approval gate. */
const exitPlanModeTool = defineTool<string>({
  name: 'exit_plan_mode',
  description:
    'Submit the current plan for approval. This reuses the approval gate rather '
    + 'than a second plan mechanism, and answers WAITING_FOR_APPROVAL.',
  parameters: {
    plan: { type: 'string', description: 'The plan markdown, starting with a # title.' },
  },
  presentCall: _args => ({ card: 'generic', title: 'exit plan mode' }),
  output: { schema: { type: 'string' }, render: (_args, value) => [textBlock(value)] },
  async execute(args) {
    const plan = typeof args.plan === 'string' ? args.plan : '';
    return `WAITING_FOR_APPROVAL: ${plan || 'exit plan mode'}`;
  },
});

registerTool(toolSpecFrom(exitPlanModeTool, { plane: 'agent' }));

/** `ask_user_question` — put a question to the user and end the turn. */
const askUserQuestionTool = defineTool<string>({
  name: 'ask_user_question',
  description:
    'Ask the user a question and end the turn. Nothing can answer inside the same '
    + 'tool loop, so this answers WAITING_FOR_INPUT.',
  parameters: {
    question: { type: 'string', description: 'The question to ask.' },
    options: {
      type: 'array',
      description: 'Optional choices, rendered as 1 / 2 / 3 …',
      items: { type: 'string' },
    },
  },
  presentCall: args => ({ card: 'generic', title: `ask: ${oneLine(args.question)}` }),
  output: { schema: { type: 'string' }, render: (_args, value) => [textBlock(value)] },
  async execute(args, exec) {
    const host = exec.host as StandardToolHost;
    const question = args.question;
    if (typeof question !== 'string' || !question.trim()) throw new Error('question is required');
    const options = Array.isArray(args.options)
      ? args.options.filter((o): o is string => typeof o === 'string')
      : undefined;
    const now = host.now ?? (() => new Date());
    const pending: PendingQuestion = {
      id: `q-${Date.now().toString(36)}`,
      question: question.trim(),
      ...(options && options.length > 0 ? { options } : {}),
      askedAt: now().toISOString(),
    };
    host.state.pendingQuestion = pending;
    // The turn must end here: nothing can answer inside the same tool loop.
    return `WAITING_FOR_INPUT: ${pending.question}`;
  },
});

registerTool(toolSpecFrom(askUserQuestionTool, { plane: 'agent' }));

/** `list_mcp_resources` — resources exposed by the configured MCP servers. */
const listMcpResourcesTool = defineTool<string>({
  name: 'list_mcp_resources',
  description: 'List resources exposed by the configured MCP servers.',
  parameters: {
    server: { type: 'string', description: 'Limit the listing to one MCP server.' },
  },
  presentCall: _args => ({ card: 'generic', title: 'list MCP resources' }),
  output: { schema: { type: 'string' }, render: (_args, value) => [textBlock(value)] },
  async execute(args) {
    const list = await listMcpResources(typeof args.server === 'string' ? args.server : undefined);
    if (list.length === 0) return '(no resources)';
    return list.map(r => `${r.uri}\t${r.name ?? ''}\t${r.mimeType ?? ''}`).join('\n');
  },
});

/** `list_mcp_resource_templates` — URI templates the MCP servers advertise. */
const listMcpResourceTemplatesTool = defineTool<string>({
  name: 'list_mcp_resource_templates',
  description: 'List the URI templates advertised by the configured MCP servers.',
  parameters: {
    server: { type: 'string', description: 'Limit the listing to one MCP server.' },
  },
  presentCall: _args => ({ card: 'generic', title: 'list MCP templates' }),
  output: { schema: { type: 'string' }, render: (_args, value) => [textBlock(value)] },
  async execute(args) {
    const list = await listMcpResourceTemplates(
      typeof args.server === 'string' ? args.server : undefined,
    );
    if (list.length === 0) return '(no resource templates)';
    return list.map(t => `${t.uriTemplate}\t${t.name ?? ''}`).join('\n');
  },
});

/** `read_mcp_resource` — read one MCP resource by URI. */
const readMcpResourceTool = defineTool<string>({
  name: 'read_mcp_resource',
  description: 'Read one MCP resource by URI.',
  parameters: {
    uri: { type: 'string', description: 'Resource URI, as listed by list_mcp_resources.' },
    server: { type: 'string', description: 'MCP server name, when the URI is ambiguous.' },
  },
  presentCall: args => ({ card: 'generic', title: `read MCP ${oneLine(args.uri)}` }),
  output: { schema: { type: 'string' }, render: (_args, value) => [textBlock(value)] },
  async execute(args) {
    return clip(await readMcpResource(
      typeof args.uri === 'string' ? args.uri : '',
      typeof args.server === 'string' ? args.server : undefined,
    ));
  },
});

registerTool(toolSpecFrom(listMcpResourcesTool, { plane: 'host' }));
registerTool(toolSpecFrom(listMcpResourceTemplatesTool, { plane: 'host' }));
registerTool(toolSpecFrom(readMcpResourceTool, { plane: 'host' }));

/** `create_goal` — create (or replace) the session goal. */
const createGoalTool = defineTool<string>({
  name: 'create_goal',
  description: 'Create the session goal, replacing any existing one.',
  parameters: {
    objective: { type: 'string', description: 'What this session is trying to achieve.' },
    budget: { type: 'number', description: 'Optional step budget.' },
  },
  presentCall: args => ({ card: 'generic', title: `goal: ${oneLine(args.objective)}` }),
  output: { schema: { type: 'string' }, render: (_args, value) => [textBlock(value)] },
  async execute(args, exec) {
    const host = exec.host as StandardToolHost;
    if (typeof args.objective !== 'string' || !args.objective.trim()) {
      throw new Error('objective is required');
    }
    const now = host.now ?? (() => new Date());
    const goal: Goal = {
      objective: args.objective.trim(),
      status: 'active',
      budget: typeof args.budget === 'number' ? args.budget : undefined,
      createdAt: now().toISOString(),
    };
    host.state.goal = goal;
    return `OK: goal created\n${JSON.stringify(goal)}`;
  },
});

/** `get_goal` — read the current session goal. */
const getGoalTool = defineTool<string>({
  name: 'get_goal',
  description: 'Read the current session goal.',
  parameters: {},
  presentCall: _args => ({ card: 'generic', title: 'read goal' }),
  output: { schema: { type: 'string' }, render: (_args, value) => [textBlock(value)] },
  async execute(_args, exec) {
    const host = exec.host as StandardToolHost;
    return host.state.goal ? JSON.stringify(host.state.goal) : 'No goal is set.';
  },
});

/** `update_goal` — change the goal's status or objective. */
const updateGoalTool = defineTool<string>({
  name: 'update_goal',
  description: 'Update the session goal: its status, its objective, or both.',
  parameters: {
    status: { type: 'string', enum: ['active', 'paused', 'complete'] },
    objective: { type: 'string', description: 'Replacement objective.' },
  },
  presentCall: args => ({ card: 'generic', title: `goal \u2192 ${oneLine(args.status)}` }),
  output: { schema: { type: 'string' }, render: (_args, value) => [textBlock(value)] },
  async execute(args, exec) {
    const host = exec.host as StandardToolHost;
    if (!host.state.goal) throw new Error('no goal is set');
    const status = args.status;
    if (status !== undefined) {
      if (!['active', 'paused', 'complete'].includes(String(status))) {
        throw new Error('status must be active|paused|complete');
      }
      host.state.goal.status = String(status) as Goal['status'];
    }
    if (typeof args.objective === 'string' && args.objective.trim()) {
      host.state.goal.objective = args.objective.trim();
    }
    return `OK: goal updated\n${JSON.stringify(host.state.goal)}`;
  },
});

// `host.state` is per-session, but the goal lifecycle belongs to the process-level
// plane in `toolDeclarations.ts`; keep the plane there rather than drift.
registerTool(toolSpecFrom(createGoalTool, { plane: 'host' }));
registerTool(toolSpecFrom(getGoalTool, { plane: 'host' }));
registerTool(toolSpecFrom(updateGoalTool, { plane: 'host' }));

/** `schedule_create` — queue a prompt to run at a time, optionally repeating. */
const scheduleCreateTool = defineTool<string>({
  name: 'schedule_create',
  description:
    'Schedule a prompt to run at a specific time. The due-check driver in '
    + 'Server/index.ts (TRHA_SCHEDULE_TICK_MS) turns the record into a real turn.',
  parameters: {
    prompt: { type: 'string', description: 'The prompt to run.' },
    at: { type: 'string', description: 'ISO timestamp or epoch milliseconds.' },
    repeat_ms: { type: 'number', description: 'Repeat interval in milliseconds.' },
  },
  presentCall: args => ({ card: 'generic', title: `schedule ${oneLine(args.cron ?? args.when)}` }),
  output: { schema: { type: 'string' }, render: (_args, value) => [textBlock(value)] },
  async execute(args, exec) {
    const host = exec.host as StandardToolHost;
    const prompt = args.prompt;
    if (typeof prompt !== 'string' || !prompt.trim()) throw new Error('prompt is required');
    const atRaw = args.at;
    const at = typeof atRaw === 'string' ? new Date(atRaw) : new Date(Number(atRaw ?? NaN));
    if (Number.isNaN(at.getTime())) throw new Error('at must be an ISO timestamp or epoch ms');
    const schedule: Schedule = {
      id: `sch-${(host.state.schedules?.length ?? 0) + 1}`,
      prompt: prompt.trim(),
      at: at.toISOString(),
      repeatMs: typeof args.repeat_ms === 'number' ? args.repeat_ms : undefined,
      status: 'active',
    };
    host.state.schedules = [...(host.state.schedules ?? []), schedule];
    return `OK: scheduled\n${JSON.stringify(schedule)}`;
  },
});

/** `schedule_list` — every schedule on this session. */
const scheduleListTool = defineTool<string>({
  name: 'schedule_list',
  description: 'List the schedules attached to this session.',
  parameters: {},
  presentCall: _args => ({ card: 'generic', title: 'list schedules' }),
  output: { schema: { type: 'string' }, render: (_args, value) => [textBlock(value)] },
  async execute(_args, exec) {
    const host = exec.host as StandardToolHost;
    const list = host.state.schedules ?? [];
    return list.length ? list.map(s => JSON.stringify(s)).join('\n') : '(no schedules)';
  },
});

/** `schedule_update` — change one schedule's prompt, time, repeat or status. */
const scheduleUpdateTool = defineTool<string>({
  name: 'schedule_update',
  description: 'Update one schedule: prompt, time, repeat interval or status.',
  parameters: {
    id: { type: 'string', description: 'Schedule id from schedule_list.' },
    prompt: { type: 'string' },
    at: { type: 'string', description: 'ISO timestamp.' },
    repeat_ms: { type: 'number' },
    status: { type: 'string', enum: ['active', 'cancelled'] },
  },
  presentCall: args => ({ card: 'generic', title: `update schedule ${oneLine(args.id)}` }),
  output: { schema: { type: 'string' }, render: (_args, value) => [textBlock(value)] },
  async execute(args, exec) {
    const host = exec.host as StandardToolHost;
    const id = typeof args.id === 'string' ? args.id : '';
    const s = (host.state.schedules ?? []).find(x => x.id === id);
    if (!s) throw new Error(`no schedule ${id}`);
    if (typeof args.prompt === 'string' && args.prompt.trim()) s.prompt = args.prompt.trim();
    if (typeof args.at === 'string') {
      const at = new Date(args.at);
      if (Number.isNaN(at.getTime())) throw new Error('bad at');
      s.at = at.toISOString();
    }
    if (typeof args.repeat_ms === 'number') s.repeatMs = args.repeat_ms;
    if (args.status === 'active' || args.status === 'cancelled') s.status = args.status;
    return `OK: updated\n${JSON.stringify(s)}`;
  },
});

/** `schedule_delete` — remove one schedule. */
const scheduleDeleteTool = defineTool<string>({
  name: 'schedule_delete',
  description: 'Delete one schedule by id.',
  parameters: { id: { type: 'string', description: 'Schedule id from schedule_list.' } },
  presentCall: args => ({ card: 'generic', title: `delete schedule ${oneLine(args.id)}` }),
  output: { schema: { type: 'string' }, render: (_args, value) => [textBlock(value)] },
  async execute(args, exec) {
    const host = exec.host as StandardToolHost;
    const id = typeof args.id === 'string' ? args.id : '';
    const before = host.state.schedules ?? [];
    const after = before.filter(s => s.id !== id);
    if (after.length === before.length) throw new Error(`no schedule ${id}`);
    host.state.schedules = after;
    return `OK: deleted ${id}`;
  },
});

registerTool(toolSpecFrom(scheduleCreateTool, { plane: 'host' }));
registerTool(toolSpecFrom(scheduleListTool, { plane: 'host' }));
registerTool(toolSpecFrom(scheduleUpdateTool, { plane: 'host' }));
registerTool(toolSpecFrom(scheduleDeleteTool, { plane: 'host' }));

/** `team_task_create` — add an entry to the shared team task list. */
const teamTaskCreateTool = defineTool<string>({
  name: 'team_task_create',
  description: 'Add a task to the shared team task list that subagents can pick up.',
  parameters: {
    subject: { type: 'string', description: 'One-line summary.' },
    description: { type: 'string', description: 'What the task involves.' },
    assignee: { type: 'string', description: 'Teammate name, when already decided.' },
  },
  presentCall: args => ({ card: 'generic', title: `task: ${oneLine(args.title ?? args.subject)}` }),
  output: { schema: { type: 'string' }, render: (_args, value) => [textBlock(value)] },
  async execute(args, exec) {
    const host = exec.host as StandardToolHost;
    if (!host.agents) throw new Error('team tasks are not available in this host');
    const subject = typeof args.subject === 'string' ? args.subject.trim() : '';
    if (!subject) throw new Error('subject is required');
    const tasks = host.agents.teamTasks();
    const task: TeamTask = {
      id: `t${tasks.length + 1}`,
      subject,
      ...(typeof args.description === 'string' ? { description: args.description } : {}),
      status: 'pending',
      ...(typeof args.assignee === 'string' ? { assignee: args.assignee } : {}),
    };
    host.agents.setTeamTasks([...tasks, task]);
    return `OK: ${JSON.stringify(task)}`;
  },
});

/** `team_task_list` — every shared team task. */
const teamTaskListTool = defineTool<string>({
  name: 'team_task_list',
  description: 'List the shared team tasks.',
  parameters: {},
  presentCall: _args => ({ card: 'generic', title: 'list tasks' }),
  output: { schema: { type: 'string' }, render: (_args, value) => [textBlock(value)] },
  async execute(_args, exec) {
    const host = exec.host as StandardToolHost;
    if (!host.agents) throw new Error('team tasks are not available in this host');
    const tasks = host.agents.teamTasks();
    return tasks.length ? tasks.map(t => JSON.stringify(t)).join('\n') : '(no team tasks)';
  },
});

/** `team_task_update` — change one team task's status, assignee or description. */
const teamTaskUpdateTool = defineTool<string>({
  name: 'team_task_update',
  description: 'Update one shared team task.',
  parameters: {
    id: { type: 'string', description: 'Task id from team_task_list.' },
    status: { type: 'string', enum: ['pending', 'in_progress', 'completed'] },
    assignee: { type: 'string' },
    description: { type: 'string' },
  },
  presentCall: args => ({ card: 'generic', title: `update task ${oneLine(args.id)}` }),
  output: { schema: { type: 'string' }, render: (_args, value) => [textBlock(value)] },
  async execute(args, exec) {
    const host = exec.host as StandardToolHost;
    if (!host.agents) throw new Error('team tasks are not available in this host');
    const id = typeof args.id === 'string' ? args.id : '';
    const tasks = host.agents.teamTasks();
    const t = tasks.find(x => x.id === id);
    if (!t) throw new Error(`no team task ${id}`);
    if (args.status === 'pending' || args.status === 'in_progress' || args.status === 'completed') {
      t.status = args.status;
    }
    if (typeof args.assignee === 'string') t.assignee = args.assignee;
    if (typeof args.description === 'string') t.description = args.description;
    host.agents.setTeamTasks(tasks);
    return `OK: ${JSON.stringify(t)}`;
  },
});

registerTool(toolSpecFrom(teamTaskCreateTool, { plane: 'host' }));
registerTool(toolSpecFrom(teamTaskListTool, { plane: 'host' }));
registerTool(toolSpecFrom(teamTaskUpdateTool, { plane: 'host' }));

/** `browser_navigate` — open a URL in the session's headless browser. */
const browserNavigateTool = defineTool<string>({
  name: 'browser_navigate',
  description: 'Navigate the session\'s headless browser to a URL and return the visible text.',
  parameters: { url: { type: 'string', description: 'Absolute http(s) URL.' } },
  presentCall: args => ({ card: 'generic', title: `open ${oneLine(args.url)}` }),
  output: { schema: { type: 'string' }, render: (_args, value) => [textBlock(value)] },
  async execute(args, exec) {
    const host = exec.host as StandardToolHost;
    const url = typeof args.url === 'string' ? args.url : '';
    if (!url) throw new Error('url is required');
    const page = await browserNavigate(host.sessionId, url);
    return clip(`title: ${page.title}\nurl: ${page.url}\n\n${page.text}`);
  },
});

/** `browser_extract` — text of the current page, optionally one selector. */
const browserExtractTool = defineTool<string>({
  name: 'browser_extract',
  description: 'Extract text from the current page, or from one CSS selector.',
  parameters: { selector: { type: 'string', description: 'CSS selector to narrow to.' } },
  presentCall: _args => ({ card: 'generic', title: 'extract page text' }),
  output: { schema: { type: 'string' }, render: (_args, value) => [textBlock(value)] },
  async execute(args, exec) {
    const host = exec.host as StandardToolHost;
    return clip(await browserExtract(
      host.sessionId,
      typeof args.selector === 'string' ? args.selector : undefined,
    ));
  },
});

/** `browser_screenshot` — capture the current page into the workspace. */
const browserScreenshotTool = defineTool<string>({
  name: 'browser_screenshot',
  description: 'Screenshot the current page into the workspace.',
  parameters: {
    path: { type: 'string', description: 'Target file; a temp name is used when omitted.' },
  },
  presentCall: _args => ({ card: 'generic', title: 'screenshot' }),
  output: { schema: { type: 'string' }, render: (_args, value) => [textBlock(value)] },
  async execute(args, exec) {
    const host = exec.host as StandardToolHost;
    const file = await browserScreenshot(
      host.sessionId,
      host.workspace,
      typeof args.path === 'string' ? args.path : undefined,
    );
    return `OK: screenshot -> ${file}`;
  },
});

/** `browser_close` — tear down the session's browser. */
const browserCloseTool = defineTool<string>({
  name: 'browser_close',
  description: 'Close the session\'s headless browser.',
  parameters: {},
  presentCall: _args => ({ card: 'generic', title: 'close browser' }),
  output: { schema: { type: 'string' }, render: (_args, value) => [textBlock(value)] },
  async execute(_args, exec) {
    const host = exec.host as StandardToolHost;
    await browserClose(host.sessionId);
    return 'OK: browser closed for this session';
  },
});

registerTool(toolSpecFrom(browserNavigateTool, { plane: 'agent' }));
registerTool(toolSpecFrom(browserExtractTool, { plane: 'agent' }));
registerTool(toolSpecFrom(browserScreenshotTool, { plane: 'agent' }));
registerTool(toolSpecFrom(browserCloseTool, { plane: 'agent' }));

/** `list_agents` — the subagents of this session. */
const listAgentsTool = defineTool<string>({
  name: 'list_agents',
  description: 'List this session\'s subagents: id, busy/idle, message count, parent.',
  parameters: {},
  presentCall: _args => ({ card: 'generic', title: 'list agents' }),
  output: { schema: { type: 'string' }, render: (_args, value) => [textBlock(value)] },
  async execute(_args, exec) {
    const host = exec.host as StandardToolHost;
    if (!host.agents) throw new Error('subagents are not available in this host');
    const list = host.agents.list();
    if (list.length === 0) return '(no agents)';
    return list.map(a =>
      `${a.id}\t${a.busy ? 'busy' : 'idle'}\t${a.messages} msgs${a.parentId ? `\tparent=${a.parentId}` : ''}`,
    ).join('\n');
  },
});

/** `send_message` — deliver a message to one subagent. */
const sendMessageTool = defineTool<string>({
  name: 'send_message',
  description: 'Send a message to one subagent; returns its reply when it answers inline.',
  parameters: {
    to: { type: 'string', description: 'Subagent id.' },
    text: { type: 'string', description: 'Message body.' },
  },
  presentCall: args => ({ card: 'generic', title: `message ${oneLine(args.to)}` }),
  output: { schema: { type: 'string' }, render: (_args, value) => [textBlock(value)] },
  async execute(args, exec) {
    const host = exec.host as StandardToolHost;
    if (!host.agents) throw new Error('subagents are not available in this host');
    const to = typeof args.to === 'string' ? args.to : '';
    const text = typeof args.text === 'string'
      ? args.text
      : (typeof args.message === 'string' ? args.message : '');
    if (!to || !text.trim()) throw new Error('to and text are required');
    const r = await host.agents.send(to, text.trim());
    if (!r.delivered) throw new Error(`no agent ${to}`);
    return r.reply !== undefined ? `reply from ${to}:\n${clip(r.reply)}` : `queued for ${to}`;
  },
});

/** `interrupt_agent` — set the interrupt flag on one subagent. */
const interruptAgentTool = defineTool<string>({
  name: 'interrupt_agent',
  description:
    'Interrupt a subagent. The running loop checks the flag between rounds and between '
    + 'tool calls.',
  parameters: { id: { type: 'string', description: 'Subagent id.' } },
  presentCall: args => ({ card: 'generic', title: `interrupt ${oneLine(args.id)}` }),
  output: { schema: { type: 'string' }, render: (_args, value) => [textBlock(value)] },
  async execute(args, exec) {
    const host = exec.host as StandardToolHost;
    if (!host.agents) throw new Error('subagents are not available in this host');
    const id = typeof args.id === 'string' ? args.id : '';
    if (!id) throw new Error('id is required');
    const wasBusy = host.agents.interrupt(id);
    return wasBusy ? `OK: interrupted ${id}` : `OK: ${id} was idle`;
  },
});

registerTool(toolSpecFrom(listAgentsTool, { plane: 'host' }));
registerTool(toolSpecFrom(sendMessageTool, { plane: 'host' }));
registerTool(toolSpecFrom(interruptAgentTool, { plane: 'host' }));

/** `lsp` — one LSP query against the workspace. */
const lspTool = defineTool<string>({
  name: 'lsp',
  description:
    'Ask the language server one question about a file: hover, definition, references, '
    + 'diagnostics, symbols, workspaceSymbol, implementation, callHierarchy, '
    + 'incomingCalls or outgoingCalls.',
  parameters: {
    file: { type: 'string', description: 'File path.' },
    operation: {
      type: 'string',
      enum: [
        'hover', 'definition', 'references', 'diagnostics', 'symbols',
        'workspaceSymbol', 'implementation', 'callHierarchy', 'incomingCalls', 'outgoingCalls',
      ],
    },
    line: { type: 'number', description: 'Zero-based line, for position-based operations.' },
    character: { type: 'number', description: 'Zero-based character offset.' },
    query: { type: 'string', description: 'Search text, for workspaceSymbol.' },
  },
  presentCall: args => ({ card: 'generic', title: `lsp ${oneLine(args.method ?? args.action)}` }),
  output: { schema: { type: 'string' }, render: (_args, value) => [textBlock(value)] },
  async execute(args) {
    const file = typeof args.file === 'string' ? args.file : '';
    const operation = args.operation;
    if (!file) throw new Error('file is required');
    const allowed: readonly LspOperation[] = [
      'hover', 'definition', 'references', 'diagnostics', 'symbols',
      'workspaceSymbol', 'implementation', 'callHierarchy', 'incomingCalls', 'outgoingCalls',
    ];
    if (typeof operation !== 'string' || !allowed.includes(operation as LspOperation)) {
      throw new Error(`operation must be ${allowed.join('|')}`);
    }
    const out = await lspQuery({
      file,
      operation: operation as LspOperation,
      ...(typeof args.line === 'number' ? { line: args.line } : {}),
      ...(typeof args.character === 'number' ? { character: args.character } : {}),
      ...(typeof args.query === 'string' ? { query: args.query } : {}),
    });
    return clip(out);
  },
});

registerTool(toolSpecFrom(lspTool, { plane: 'host' }));

/** `subagent` — spawn one subagent for a task and wait for its reply. */
const subagentTool = defineTool<string>({
  name: 'subagent',
  description: 'Spawn a subagent for one task and return its final reply.',
  parameters: {
    task: { type: 'string', description: 'What the subagent should do.' },
    name: { type: 'string', description: 'Name hint for the subagent.' },
    agent: { type: 'string', description: 'Named agent definition (~/.trha/agents/<name>/).' },
  },
  output: { schema: { type: 'string' }, render: (_args, value) => [textBlock(value)] },
  presentCall: args => ({ card: 'generic', title: `subagent: ${oneLine(args.task ?? args.prompt)}` }),
  // Read-only, no shared mutable state — same marking DSH uses.
  isConcurrencySafe: () => true,
  async execute(args, exec) {
    const host = exec.host as StandardToolHost;
    if (!host.agents) throw new Error('subagents are not available in this host');
    const task = typeof args.task === 'string' ? args.task.trim() : '';
    if (!task) throw new Error('task is required');
    const nameHint = typeof args.name === 'string' ? args.name : undefined;
    // Named agent definition (~/.trha/agents/<name>/), optional.
    const agentName = typeof args.agent === 'string' ? args.agent : undefined;
    const r = await host.agents.spawn(task, nameHint, agentName);
    return `subagent ${r.id} finished:\n${clip(r.reply)}`;
  },
});

/** `workflow` — run a list of {name, task} steps through fresh subagents. */
/**
 * What `workflow` produces — the step outcomes plus their serialized form, so
 * the result card reads a count instead of re-parsing the JSON.
 */
export interface WorkflowResult {
  /** How many steps ran (one entry per requested step, failed ones included). */
  steps: number;
  /** The serialized step outcomes. */
  text: string;
}

/** Reproduce the pre-refactor text byte for byte. */
const renderWorkflow = (v: WorkflowResult): string => v.text;

const workflowTool = defineTool<WorkflowResult>({
  name: 'workflow',
  description: 'Run named steps in order, each executed by a fresh subagent; returns JSON.',
  parameters: {
    steps: {
      type: 'array',
      description: 'Steps to run in order.',
      items: {
        type: 'object',
        properties: {
          name: { type: 'string', description: 'Label for this step.' },
          task: { type: 'string', description: 'Task for the subagent.' },
        },
      },
    },
  },
  presentCall: args => ({ card: 'generic', title: `workflow ${oneLine(args.name ?? args.steps)}` }),
  // The tool returns a JSON array of step outcomes; the distilled fact is how
  // many steps ran.
  presentResult: (_args, result) => {
    // The canonical value: no JSON re-parse, no failed parse on a truncated clip.
    const v = result as WorkflowResult;
    return {
      card: 'generic' as const,
      title: v?.steps ? `${v.steps} steps` : 'workflow done',
    };
  },
  output: {
    schema: {
      type: 'object',
      additionalProperties: false,
      properties: { steps: { type: 'number' }, text: { type: 'string' } },
    },
    render: (_args, value) => [textBlock(renderWorkflow(value))],
  },
  async execute(args, exec) {
    const host = exec.host as StandardToolHost;
    if (!host.agents) throw new Error('workflow is not available in this host');
    const steps = Array.isArray(args.steps) ? args.steps : [];
    if (steps.length === 0) throw new Error('steps must be a non-empty array of {name, task}');
    const out: Array<Record<string, unknown>> = [];
    for (const raw of steps) {
      const o = raw as { name?: unknown; task?: unknown };
      const task = typeof o.task === 'string' ? o.task.trim() : '';
      if (!task) { out.push({ name: String(o.name ?? ''), error: 'missing task' }); continue; }
      try {
        const r = await host.agents.spawn(task, typeof o.name === 'string' ? o.name : undefined);
        out.push({ name: String(o.name ?? r.id), agent: r.id, reply: clip(r.reply, 4000) });
      } catch (e) {
        out.push({ name: String(o.name ?? ''), error: String(e) });
      }
    }
    return { steps: out.length, text: clip(JSON.stringify(out, null, 2)) };
  },
});

registerTool(toolSpecFrom(subagentTool, { plane: 'host' }));
registerTool(toolSpecFrom(workflowTool, { plane: 'agent' }));

/** `run_code` — run a snippet from a scratch file outside the workspace. */
const runCodeTool = defineTool<string>({
  name: 'run_code',
  description:
    'Run a code snippet (python | javascript | bash | lean). The scratch file lives '
    + 'outside the workspace; cwd stays the workspace. Sandboxed when the seam is on.',
  parameters: {
    language: { type: 'string', enum: ['python', 'javascript', 'bash', 'lean'] },
    code: { type: 'string', description: 'The program body.' },
  },
  presentCall: args => ({ card: 'terminal', title: `run ${oneLine(args.language ?? 'code')}` }),
  output: { schema: { type: 'string' }, render: (_args, value) => [textBlock(value)] },
  async execute(args, exec) {
    const host = exec.host as StandardToolHost;
    const language = typeof args.language === 'string' ? args.language : '';
    const code = typeof args.code === 'string' ? args.code : '';
    if (!code.trim()) throw new Error('code is required');
    const exts: Record<string, string> = {
      python: 'py', python3: 'py', javascript: 'mjs', js: 'mjs', node: 'mjs',
      bash: 'sh', sh: 'sh', lean: 'lean',
    };
    const lang = language.toLowerCase();
    const ext = exts[lang];
    if (!ext) throw new Error(`unsupported language "${language}" (python|javascript|bash|lean)`);
    const runner = shellRunner(lang);
    // shellRunner only ever refuses bash/sh (win32); name the language instead
    // of blaming bash for a Python request.
    if (!runner.ok) {
      const hint = lang === 'bash' || lang === 'sh' ? ' (use pwsh for shell code)' : '';
      throw new Error(`${lang} is not available on this platform${hint}`);
    }
    // The scratch file must not land in the workspace. `run_code` runs on almost
    // every turn, and a crash or kill used to leave `.trha-run-*.py` next to the
    // user's sources — inside the file-history and write-sandbox surface. A
    // private dir under the OS temp root keeps the workspace clean; `cwd` below
    // stays the workspace, so relative paths in the snippet behave as before.
    const dir = sandboxEnabled()
      ? path.join(host.workspace, '.trha-run')
      : path.join(tmpdir(), 'trha-run');
    await mkdir(dir, { recursive: true, mode: 0o700 });
    const file = path.join(dir, `run-${Date.now().toString(36)}-${process.pid}.${ext}`);
    await writeFile(file, code, 'utf8');
    if (sandboxEnabled()) {
      try {
        const result = await sandboxedSpawn(defaultSandboxScope(host.workspace), {
          argv: [runner.cmd, file],
          cwd: host.workspace,
        });
        await rm(file, { force: true }).catch(() => {});
        return clip(`exit ${result.code ?? -1}\n${result.stdout}${result.stderr}`);
      } catch (e) {
        await rm(file, { force: true }).catch(() => {});
        throw new Error((e as Error).message);
      }
    }
    return await new Promise<string>(resolve => {
      const child = spawn(runner.cmd, [file], { cwd: host.workspace, env: hardenedEnv() });
      const out: string[] = [];
      const cap = (b: Buffer): void => {
        out.push(b.toString('utf8'));
        if (out.join('').length > MAX_OUTPUT_CHARS) {
          out.splice(0, out.length, out.join('').slice(-MAX_OUTPUT_CHARS));
        }
      };
      child.stdout.on('data', cap);
      child.stderr.on('data', cap);
      child.on('error', e => resolve(`ERROR: ${e.message}`));
      child.on('exit', code2 => {
        void (async () => {
          try { await rm(file, { force: true }); } catch { /* ignore */ }
          resolve(clip(`exit ${code2 ?? -1}\n${out.join('')}`));
        })();
      });
    });
  },
});

registerTool(toolSpecFrom(runCodeTool, { plane: 'agent', presets: ['ptc'] }));

/** `glob` — list files under a directory that match a glob pattern. */
const globTool = defineTool<string>({
  name: 'glob',
  description:
    'List files under a directory that match a glob pattern (`**` spans directories, '
    + '`*` and `?` stay within a segment).',
  parameters: {
    pattern: { type: 'string', description: 'Glob pattern, e.g. src/**/*.ts.' },
    path: { type: 'string', description: 'Directory to search (default ".").' },
  },
  output: { schema: { type: 'string' }, render: (_args, value) => [textBlock(value)] },
  presentCall: args => ({ card: 'generic', title: `glob ${oneLine(args.pattern)}`, rawInput: args.pattern }),
  async execute(args, exec) {
    const host = exec.host as StandardToolHost;
    if (typeof args.pattern !== 'string' || !args.pattern.trim()) {
      throw new Error('pattern is required');
    }
    // Resolve against the *session* cwd: `cd` moves it away from the workspace.
    const base = host.sessionCwd ?? host.workspace;
    const root = typeof args.path === 'string' ? args.path : '.';
    const dir = resolveReadPath(root, base);
    if (!dir) throw new Error('path must be a string');
    const found = await walkFiles(dir, 4000);
    const re = globToRegExp(args.pattern);
    const hits = found
      .filter(f => re.test(path.relative(dir, f)))
      .slice(0, 200)
      .map(f => path.relative(dir, f));
    return hits.length ? hits.join('\n') : '(no matches)';
  },
});

registerTool(toolSpecFrom(globTool, { plane: 'agent' }));

/** `grep` — regex search across file contents. */
/**
 * What `grep` produces — DSH's `tool-fs-search` returns a structured result, so
 * its result card can read a count instead of re-parsing rows.
 */
export interface GrepResult {
  /** How many hits were returned (the tool caps at 200). */
  hits: number;
  /** The formatted `path:line:text` rows, or `(no matches)`. */
  text: string;
}

/** Reproduce the pre-refactor text byte for byte. */
const renderGrep = (v: GrepResult): string => v.text;

const grepTool = defineTool<GrepResult>({
  name: 'grep',
  description:
    'Search file contents with a regular expression (multiline). Skips binaries and '
    + 'returns at most 200 hits as path:line:text.',
  parameters: {
    pattern: { type: 'string', description: 'Regular expression to search for.' },
    path: { type: 'string', description: 'Directory to search (default ".").' },
    glob: { type: 'string', description: 'Only search files matching this glob.' },
  },
  output: {
    schema: {
      type: 'object',
      additionalProperties: false,
      properties: { hits: { type: 'number' }, text: { type: 'string' } },
    },
    render: (_args, value) => [textBlock(renderGrep(value))],
  },
  presentCall: args => ({ card: 'generic', title: `grep ${oneLine(args.pattern)}`, rawInput: args.pattern }),
  // DSH's `tool-fs-search` presents a result card; the distilled fact is the
  // number of hits.
  presentResult: (_args, result) => {
    // The canonical value: no row counting, and no miscount when a matched line
    // itself contains a newline.
    const v = result as GrepResult;
    if (!v?.hits) return { card: 'generic' as const, title: 'no matches' };
    return { card: 'generic' as const, title: `${v.hits} hit${v.hits === 1 ? '' : 's'}` };
  },
  async execute(args, exec) {
    const host = exec.host as StandardToolHost;
    if (typeof args.pattern !== 'string' || !args.pattern) throw new Error('pattern is required');
    let re: RegExp;
    try {
      re = new RegExp(args.pattern, 'm');
    } catch (e) {
      throw new Error(`invalid pattern: ${(e as Error).message}`);
    }
    // Resolve against the *session* cwd: `cd` moves it away from the workspace.
    const base = host.sessionCwd ?? host.workspace;
    const dir = resolveReadPath(typeof args.path === 'string' ? args.path : '.', base);
    if (!dir) throw new Error('path must be a string');
    const only = typeof args.glob === 'string' ? globToRegExp(args.glob) : null;
    const files = await walkFiles(dir, 4000);
    const out: string[] = [];
    for (const f of files) {
      const rel = path.relative(dir, f);
      if (only && !only.test(rel)) continue;
      let text: string;
      try {
        text = await readFile(f, 'utf8');
      } catch {
        continue;
      }
      if (text.includes('\u0000')) continue; // binary
      const lines = text.split('\n');
      for (let i = 0; i < lines.length; i++) {
        if (re.test(lines[i] ?? '')) {
          out.push(`${rel}:${i + 1}:${(lines[i] ?? '').slice(0, 300)}`);
          if (out.length >= 200) break;
        }
      }
      if (out.length >= 200) break;
    }
    return {
      hits: out.length,
      text: out.length ? out.join('\n') : '(no matches)',
    };
  },
});

registerTool(toolSpecFrom(grepTool, { plane: 'agent' }));

/** `read` — read a text file, optionally a line window. */
const readTool = defineTool<string>({
  name: 'read',
  description: 'Read a text file. Lines come back numbered; `offset`/`limit` window them.',
  parameters: {
    path: { type: 'string', description: 'File path, absolute or relative to cwd.' },
    offset: { type: 'number', description: '1-based first line to return.' },
    limit: { type: 'number', description: 'How many lines to return.' },
  },
  output: { schema: { type: 'string' }, render: (_args, value) => [textBlock(value)] },
  presentCall: args => ({ card: 'generic', title: `read ${oneLine(args.path)}`, rawInput: args.path }),
  // Read-only, no shared mutable state — same marking DSH uses.
  isConcurrencySafe: () => true,
  async execute(args, exec) {
    const host = exec.host as StandardToolHost;
    const base = host.sessionCwd ?? host.workspace;
    const target = resolveReadPath(args.path, base);
    if (!target) throw new Error('missing/invalid path argument');
    const text = await readFile(target, 'utf8');
    const lines = text.split('\n');
    const offset = Number(args.offset);
    const limit = Number(args.limit);
    const start = Number.isFinite(offset) && offset > 0 ? Math.floor(offset) - 1 : 0;
    const count = Number.isFinite(limit) && limit > 0 ? Math.floor(limit) : lines.length;
    const slice = lines.slice(start, start + count);
    return limitOutput(slice.map((l, i) => `${start + i + 1}\t${l}`).join('\n'));
  },
});

registerTool(toolSpecFrom(readTool, { plane: 'agent' }));

/** Shared execute body for `write` and `append_file`. */
/**
 * What `write` / `append_file` produce — DSH's `tool-fs/write` shape, which
 * carries the path and byte count instead of a pre-formatted string.
 */
export interface WriteResult {
  /** Absolute path written. */
  path: string;
  /** Characters written (UTF-16 units, same number the old string reported). */
  bytes: number;
  mode: 'write' | 'append';
}

/** Reproduce the pre-refactor text byte for byte. */
const renderWrite = (v: WriteResult): string =>
  `OK: ${v.mode === 'write' ? 'write' : 'append_file'} -> ${v.path} (${v.bytes} chars)`;

async function writeFileExecute(
  args: Record<string, unknown>,
  exec: { host: unknown },
  mode: 'write' | 'append',
): Promise<WriteResult> {
  const host = exec.host as StandardToolHost;
  const base = host.sessionCwd ?? host.workspace;
  if (typeof args.path !== 'string') throw new Error('path must be a string');
  // Relative paths are relative to the *workspace*, not to whatever cwd the
  // scheduler happens to have — the model has no way to know the latter, and
  // "path escapes the workspace" for "hello.txt" is a dead end. Confine to the
  // *session's* workspace, not the process-wide one: with several clients on
  // different projects, WORKSPACE belongs to whoever started the scheduler.
  const target = await confineWritePath(
    base,
    workspaceRelative(args.path, base),
    host.writeRoots ?? [],
  );
  if (!target) throw new Error('path escapes the workspace');
  const rawContent = args.content;
  if (rawContent === undefined || rawContent === null) throw new Error('missing content');
  const content = typeof rawContent === 'string' ? rawContent : JSON.stringify(rawContent);
  if (mode === 'write') {
    await mkdir(path.dirname(target), { recursive: true });
    await snapshotFile(target);
    await writeFile(target, content, 'utf8');
  } else {
    await snapshotFile(target);
    await appendFile(target, content, 'utf8');
  }
  return { path: target, bytes: content.length, mode };
}

/** `write` — create or replace a file inside the workspace. */
const writeTool = defineTool<WriteResult>({
  name: 'write',
  description:
    'Create or replace a file inside the workspace. Relative paths resolve against '
    + 'the cwd; writes outside the workspace are refused.',
  parameters: {
    path: { type: 'string', description: 'File path.' },
    content: { type: 'string', description: 'Full file contents.' },
  },
  output: {
    schema: {
      type: 'object',
      additionalProperties: false,
      properties: {
        path: { type: 'string' },
        bytes: { type: 'number' },
        mode: { type: 'string' },
      },
    },
    render: (_args, value) => [textBlock(renderWrite(value))],
    // DSH's tool-fs/write exposes the written path the same way.
    presentationMeta: (_args, value) => ({ path: value.path }),
  },
  presentCall: args => ({ card: 'diff', title: `write ${oneLine(args.path)}`, rawInput: args.path }),
  // DSH's `tool-fs/write` presents its result too; here the useful summary is
  // how much landed on disk.
  presentResult: (args, result) => {
    const v = result as WriteResult;
    return { card: 'diff' as const, title: `wrote ${oneLine(args.path)}${v?.bytes ? ` · ${v.bytes}` : ''}` };
  },
  execute: (args, exec) => writeFileExecute(args, exec, 'write'),
});

/** `append_file` — append to a file inside the workspace. */
const appendFileTool = defineTool<WriteResult>({
  name: 'append_file',
  description: 'Append text to a file inside the workspace.',
  parameters: {
    path: { type: 'string', description: 'File path.' },
    content: { type: 'string', description: 'Text to append.' },
  },
  presentCall: args => ({ card: 'diff', title: `append ${oneLine(args.path)}`, rawInput: args.path }),
  output: {
    schema: {
      type: 'object',
      additionalProperties: false,
      properties: {
        path: { type: 'string' },
        bytes: { type: 'number' },
        mode: { type: 'string' },
      },
    },
    render: (_args, value) => [textBlock(renderWrite(value))],
    // DSH's tool-fs/write exposes the written path the same way.
    presentationMeta: (_args, value) => ({ path: value.path }),
  },
  execute: (args, exec) => writeFileExecute(args, exec, 'append'),
});

registerTool(toolSpecFrom(writeTool, { plane: 'agent' }));
registerTool(toolSpecFrom(appendFileTool, { plane: 'agent' }));

/** `edit` — replace one string in a file, with a unified diff in the result. */
/**
 * What `edit` produces — DSH's `tool-fs/edit` returns `{ path, before, after }`,
 * which is what lets its `presentationMeta` build hunk diffs.
 */
export interface EditResult {
  /** Absolute path actually written. */
  path: string;
  /** How many occurrences were replaced. */
  replacements: number;
  /** The unified diff, computed once in `execute`. */
  diff: string;
  /** The two fragments; DSH derives presentation hunks from these. */
  oldText: string;
  newText: string;
}

/** Reproduce the pre-refactor text byte for byte. */
const renderEdit = (v: EditResult): string => {
  const summary = `OK: edit -> ${v.path} `
    + `(${v.replacements} replacement${v.replacements === 1 ? '' : 's'})`;
  return v.diff ? `${summary}\n\n${v.diff}` : summary;
};

const editTool = defineTool<EditResult>({
  name: 'edit',
  description:
    'Replace a string in a file. Fails when the old string is missing or matches more '
    + 'than once unless `replace_all` is set. The result carries a unified diff.',
  parameters: {
    path: { type: 'string', description: 'File path.' },
    old_string: { type: 'string', description: 'Text to replace.' },
    new_string: { type: 'string', description: 'Replacement text.' },
    replace_all: { type: 'boolean', description: 'Replace every occurrence.' },
  },
  output: {
    schema: {
      type: 'object',
      additionalProperties: false,
      properties: {
        path: { type: 'string' },
        replacements: { type: 'number' },
        diff: { type: 'string' },
        oldText: { type: 'string' },
        newText: { type: 'string' },
      },
    },
    render: (_args, value) => [textBlock(renderEdit(value))],
    // DSH's tool-fs/edit shape: the path plus the fragments that produced hunks.
    presentationMeta: (_args, value) => ({
      path: value.path,
      diffs: [{ path: value.path, oldText: value.oldText, newText: value.newText }],
    }),
  },
  presentCall: args => ({ card: 'diff', title: `edit ${oneLine(args.path)}`, rawInput: args.path }),
  presentResult: (args, result) => {
    // The canonical value, not the rendered text.
    const v = result as EditResult;
    return {
      card: 'diff' as const,
      title: `edited ${oneLine(args.path)}${v?.replacements ? ` · ${v.replacements}` : ''}`,
    };
  },
  async execute(args, exec) {
    const host = exec.host as StandardToolHost;
    const base = host.sessionCwd ?? host.workspace;
    if (typeof args.path !== 'string') throw new Error('path must be a string');
    const oldString = args.old_string;
    const newString = args.new_string;
    if (typeof oldString !== 'string' || oldString === '') throw new Error('old_string is required');
    if (typeof newString !== 'string') throw new Error('new_string is required');
    const target = await confineWritePath(
      base,
      workspaceRelative(args.path, base),
      host.writeRoots ?? [],
    );
    if (!target) throw new Error('path escapes the workspace');
    const before = await readFile(target, 'utf8');
    const parts = before.split(oldString);
    const hits = parts.length - 1;
    if (hits === 0) throw new Error(`old_string not found in ${target}`);
    if (hits > 1 && args.replace_all !== true) {
      throw new Error(
        `old_string matches ${hits} times in ${target}; pass replace_all or make it unique`,
      );
    }
    const after = args.replace_all === true
      ? parts.join(newString)
      : [parts[0], ...parts.slice(1)].join(newString);
    await snapshotFile(target);
    await writeFile(target, after, 'utf8');
    return {
      path: target,
      replacements: hits,
      diff: editDiff(before, oldString, newString),
      oldText: oldString,
      newText: newString,
    };
  },
});

registerTool(toolSpecFrom(editTool, { plane: 'agent' }));

/**
 * What `bash` produces — the structured shape DSH's tool-bash returns.
 *
 * The model still sees the same text (`renderBash` reproduces the old string
 * exactly); what changes is that `presentResult` and `presentationMeta` can read
 * fields instead of re-parsing that text.
 */
export interface BashResult {
  /** Set when the call started a background job instead of running inline. */
  jobId?: string;
  /** Exit code of the one-shot run; absent for background jobs. */
  code?: number;
  stdout?: string;
  stderr?: string;
  /** Where the command ran — DSH exposes this via `presentationMeta`. */
  cwd: string;
  /** Extra explanation (timeout, sandbox note); absent when there is nothing. */
  note?: string;
}

/** Reproduce the pre-refactor text byte for byte. */
const renderBash = (v: BashResult): string => {
  if (v.jobId !== undefined) return `OK: started ${v.jobId} (use job_output to read it)`;
  const body = `exit ${v.code ?? -1}\n${v.stdout ?? ''}`
    + `${v.stderr ? `\n[stderr]\n${v.stderr}` : ''}`;
  return limitOutput(v.note ? `${body}\n${v.note}` : body);
};

/** `bash` — run one shell command (optionally as a background job). */
const bashTool = defineTool<BashResult>({
  name: 'bash',
  description:
    'Run one shell command in the working directory. Set `background: true` to start it '
    + 'as a job and read it later with job_output.',
  parameters: {
    command: { type: 'string', description: 'The command line.' },
    background: { type: 'boolean', description: 'Run as a background job.' },
  },
  output: {
    schema: {
      type: 'object',
      additionalProperties: false,
      properties: {
        jobId: { type: 'string' },
        code: { type: 'number' },
        stdout: { type: 'string' },
        stderr: { type: 'string' },
        cwd: { type: 'string' },
        note: { type: 'string' },
      },
    },
    render: (_args, value) => [textBlock(renderBash(value))],
    // DSH's tool-bash exposes the working directory this way.
    presentationMeta: (_args, value) => ({ cwd: value.cwd }),
  },
  presentCall: args => ({ card: 'terminal', title: oneLine(args.command), rawInput: args.command }),
  presentResult: (_args, result) => {
    // The canonical value, not the rendered text: no regex needed any more.
    const v = result as BashResult;
    if (v?.jobId !== undefined) return { card: 'terminal' as const, title: `job ${v.jobId}` };
    return v?.code !== undefined
      ? { card: 'terminal' as const, title: `exit ${v.code}` }
      : undefined;
  },
  async execute(args, exec) {
    const host = exec.host as StandardToolHost;
    const cmd = typeof args.command === 'string' ? args.command : '';
    if (!cmd.trim()) throw new Error('missing command');
    const cwd = host.sessionCwd ?? host.workspace;
    if (args.background === true) {
      const id = startJob(host, cmd);
      return { jobId: id, cwd };
    }
    const r = await runShell(cmd, { cwd });
    return {
      code: r.code,
      stdout: r.stdout,
      stderr: r.stderr,
      cwd,
      ...(r.note ? { note: r.note } : {}),
    };
  },
});

registerTool(toolSpecFrom(bashTool, { plane: 'agent' }));
