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
import { mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { discoverSkills, readSkill, skillDirs } from './skills.js';
import { listMcpResources, listMcpResourceTemplates, readMcpResource } from './mcp.js';
import { hardenedEnv, resolveShell, shellRunner } from './shell.js';
import { defaultSandboxScope, sandboxBlocksNetwork, sandboxEnabled, sandboxedSpawn } from './sandbox.js';
import { registerTool, renderToolValue, resolveTool } from './toolRegistry.js';
import { defineTool, textBlock, toolSpecFrom } from './toolSchema.js';
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
): Promise<string | null> {
  // Registered tools take precedence over the legacy chain, so migration is
  // one tool at a time: anything not yet registered still runs below.
  const registered = resolveTool(name);
  if (registered?.handler) return renderToolValue(registered, args, host);


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
    const url = typeof args.url === 'string' ? args.url : '';
    if (!url) return 'ERROR: url is required';
    try {
      const page = await browserNavigate(host.sessionId, url);
      return clip(`title: ${page.title}\nurl: ${page.url}\n\n${page.text}`);
    } catch (e) {
      return `ERROR: ${(e as Error).message}`;
    }
  }

  if (name === 'browser_extract') {
    try {
      return clip(await browserExtract(host.sessionId, typeof args.selector === 'string' ? args.selector : undefined));
    } catch (e) {
      return `ERROR: ${(e as Error).message}`;
    }
  }

  if (name === 'browser_screenshot') {
    try {
      const file = await browserScreenshot(host.sessionId, host.workspace, typeof args.path === 'string' ? args.path : undefined);
      return `OK: screenshot -> ${file}`;
    } catch (e) {
      return `ERROR: ${(e as Error).message}`;
    }
  }

  if (name === 'browser_close') {
    await browserClose(host.sessionId);
    return 'OK: browser closed for this session';
  }

  if (name === 'lsp') {
    const file = typeof args.file === 'string' ? args.file : '';
    const operation = args.operation;
    if (!file) return 'ERROR: file is required';
    const allowed: readonly LspOperation[] = [
      'hover', 'definition', 'references', 'diagnostics', 'symbols',
      'workspaceSymbol', 'implementation', 'callHierarchy', 'incomingCalls', 'outgoingCalls',
    ];
    if (typeof operation !== 'string' || !allowed.includes(operation as LspOperation)) {
      return `ERROR: operation must be ${allowed.join('|')}`;
    }
    try {
      const out = await lspQuery({
        file,
        operation: operation as LspOperation,
        ...(typeof args.line === 'number' ? { line: args.line } : {}),
        ...(typeof args.character === 'number' ? { character: args.character } : {}),
        ...(typeof args.query === 'string' ? { query: args.query } : {}),
      });
      return clip(out);
    } catch (e) {
      return `ERROR: ${(e as Error).message}`;
    }
  }

  if (name === 'subagent') {
    if (!host.agents) return 'ERROR: subagents are not available in this host';
    const task = typeof args.task === 'string' ? args.task.trim() : '';
    if (!task) return 'ERROR: task is required';
    const nameHint = typeof args.name === 'string' ? args.name : undefined;
    // Named agent definition (~/.trha/agents/<name>/), optional.
    const agentName = typeof args.agent === 'string' ? args.agent : undefined;
    const r = await host.agents.spawn(task, nameHint, agentName);
    return `subagent ${r.id} finished:\n${clip(r.reply)}`;
  }

  if (name === 'list_agents') {
    if (!host.agents) return 'ERROR: subagents are not available in this host';
    const list = host.agents.list();
    if (list.length === 0) return '(no agents)';
    return list.map(a =>
      `${a.id}\t${a.busy ? 'busy' : 'idle'}\t${a.messages} msgs${a.parentId ? `\tparent=${a.parentId}` : ''}`,
    ).join('\n');
  }

  if (name === 'send_message') {
    if (!host.agents) return 'ERROR: subagents are not available in this host';
    const to = typeof args.to === 'string' ? args.to : '';
    const text = typeof args.text === 'string' ? args.text : (typeof args.message === 'string' ? args.message : '');
    if (!to || !text.trim()) return 'ERROR: to and text are required';
    const r = await host.agents.send(to, text.trim());
    if (!r.delivered) return `ERROR: no agent ${to}`;
    return r.reply !== undefined ? `reply from ${to}:\n${clip(r.reply)}` : `queued for ${to}`;
  }

  if (name === 'interrupt_agent') {
    if (!host.agents) return 'ERROR: subagents are not available in this host';
    const id = typeof args.id === 'string' ? args.id : '';
    if (!id) return 'ERROR: id is required';
    // The running loop checks this flag between rounds and between tool calls.
    const wasBusy = host.agents.interrupt(id);
    return wasBusy ? `OK: interrupted ${id}` : `OK: ${id} was idle`;
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
    if (!host.agents) return 'ERROR: workflow is not available in this host';
    const steps = Array.isArray(args.steps) ? args.steps : [];
    if (steps.length === 0) return 'ERROR: steps must be a non-empty array of {name, task}';
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
    return clip(JSON.stringify(out, null, 2));
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
    const language = typeof args.language === 'string' ? args.language : '';
    const code = typeof args.code === 'string' ? args.code : '';
    if (!code.trim()) return 'ERROR: code is required';
    const exts: Record<string, string> = {
      python: 'py', python3: 'py', javascript: 'mjs', js: 'mjs', node: 'mjs',
      bash: 'sh', sh: 'sh', lean: 'lean',
    };
    const lang = language.toLowerCase();
    const ext = exts[lang];
    if (!ext) return `ERROR: unsupported language "${language}" (python|javascript|bash|lean)`;
    const runner = shellRunner(lang);
    // shellRunner only ever refuses bash/sh (win32); name the language instead
    // of blaming bash for a Python request.
    if (!runner.ok) {
      const hint = lang === 'bash' || lang === 'sh' ? ' (use pwsh for shell code)' : '';
      return `ERROR: ${lang} is not available on this platform${hint}`;
    }
    // The scratch file must not land in the workspace. `run_code` runs on
    // almost every turn, and a crash or a kill used to leave `.trha-run-*.py`
    // sitting next to the user's sources — inside the file-history and write
    // sandbox surface, and, when the workspace itself was mis-resolved, in
    // whichever subdirectory the scheduler happened to be launched from.
    // A private dir under the OS temp root keeps the workspace clean; `cwd`
    // below stays the workspace, so relative paths in the snippet behave the
    // same as before.
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
        return `ERROR: ${(e as Error).message}`;
      }
    }
    return await new Promise<string>(resolve => {
      const child = spawn(runner.cmd, [file], { cwd: host.workspace, env: hardenedEnv() });
      const out: string[] = [];
      const cap = (b: Buffer): void => {
        out.push(b.toString('utf8'));
        if (out.join('').length > MAX_OUTPUT_CHARS) out.splice(0, out.length, out.join('').slice(-MAX_OUTPUT_CHARS));
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
