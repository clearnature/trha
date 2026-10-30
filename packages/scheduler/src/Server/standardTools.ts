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
import { registerTool, resolveTool } from './toolRegistry.js';
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
  if (registered?.handler) return registered.handler(args, host);

  const now = host.now ?? (() => new Date());

  if (name === 'list_mcp_resources') {
    try {
      const list = await listMcpResources(typeof args.server === 'string' ? args.server : undefined);
      if (list.length === 0) return '(no resources)';
      return list.map(r => `${r.uri}\t${r.name ?? ''}\t${r.mimeType ?? ''}`).join('\n');
    } catch (e) {
      return `ERROR: ${(e as Error).message}`;
    }
  }

  if (name === 'list_mcp_resource_templates') {
    try {
      const list = await listMcpResourceTemplates(typeof args.server === 'string' ? args.server : undefined);
      if (list.length === 0) return '(no resource templates)';
      return list.map(t => `${t.uriTemplate}\t${t.name ?? ''}`).join('\n');
    } catch (e) {
      return `ERROR: ${(e as Error).message}`;
    }
  }

  if (name === 'read_mcp_resource') {
    try {
      return clip(await readMcpResource(
        typeof args.uri === 'string' ? args.uri : '',
        typeof args.server === 'string' ? args.server : undefined,
      ));
    } catch (e) {
      return `ERROR: ${(e as Error).message}`;
    }
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
    if (!host.agents) return 'ERROR: team tasks are not available in this host';
    const subject = typeof args.subject === 'string' ? args.subject.trim() : '';
    if (!subject) return 'ERROR: subject is required';
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
  }

  if (name === 'team_task_list') {
    if (!host.agents) return 'ERROR: team tasks are not available in this host';
    const tasks = host.agents.teamTasks();
    return tasks.length ? tasks.map(t => JSON.stringify(t)).join('\n') : '(no team tasks)';
  }

  if (name === 'team_task_update') {
    if (!host.agents) return 'ERROR: team tasks are not available in this host';
    const id = typeof args.id === 'string' ? args.id : '';
    const tasks = host.agents.teamTasks();
    const t = tasks.find(x => x.id === id);
    if (!t) return `ERROR: no team task ${id}`;
    if (args.status === 'pending' || args.status === 'in_progress' || args.status === 'completed') {
      t.status = args.status;
    }
    if (typeof args.assignee === 'string') t.assignee = args.assignee;
    if (typeof args.description === 'string') t.description = args.description;
    host.agents.setTeamTasks(tasks);
    return `OK: ${JSON.stringify(t)}`;
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
    const question = args.question;
    if (typeof question !== 'string' || !question.trim()) return 'ERROR: question is required';
    const options = Array.isArray(args.options)
      ? args.options.filter((o): o is string => typeof o === 'string')
      : undefined;
    const pending: PendingQuestion = {
      id: `q-${Date.now().toString(36)}`,
      question: question.trim(),
      ...(options && options.length > 0 ? { options } : {}),
      askedAt: now().toISOString(),
    };
    host.state.pendingQuestion = pending;
    // The turn must end here: nothing can answer inside the same tool loop.
    return `WAITING_FOR_INPUT: ${pending.question}`;
  }

  if (name === 'exit_plan_mode') {
    // Reuses the approval gate instead of inventing a second plan mechanism.
    const plan = typeof args.plan === 'string' ? args.plan : '';
    return `WAITING_FOR_APPROVAL: ${plan || 'exit plan mode'}`;
  }

  if (name === 'present') {
    const title = typeof args.title === 'string' ? args.title : '';
    const body = typeof args.body === 'string' ? args.body : '';
    if (!title && !body) return 'ERROR: title or body is required';
    return `PRESENT: ${JSON.stringify({ title, body })}`;
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
    const raw = args.path;
    if (typeof raw !== 'string' || !raw.trim()) return 'ERROR: path is required';
    const file = path.isAbsolute(raw) ? raw : path.join(host.workspace, raw);
    try {
      const buf = await readFile(file);
      if (buf.byteLength > 2 * 1024 * 1024) {
        return `ERROR: image is ${buf.byteLength} bytes; the cap is 2 MiB`;
      }
      const ext = path.extname(file).toLowerCase();
      const mime = ext === '.png' ? 'image/png'
        : ext === '.jpg' || ext === '.jpeg' ? 'image/jpeg'
        : ext === '.gif' ? 'image/gif'
        : ext === '.webp' ? 'image/webp' : 'application/octet-stream';
      return `data:${mime};base64,${buf.toString('base64')}`;
    } catch (e) {
      return `ERROR: ${(e as Error).message}`;
    }
  }

  if (name === 'todo_write') {
    const raw = args.todos;
    if (!Array.isArray(raw)) return 'ERROR: todos must be an array';
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
    const lines = todos.map(t => `- [${t.status === 'completed' ? 'x' : t.status === 'in_progress' ? '~' : ' '}] ${t.text}`);
    return `OK: ${todos.length} todos\n${lines.join('\n')}`;
  }

  if (name === 'create_goal') {
    if (typeof args.objective !== 'string' || !args.objective.trim()) return 'ERROR: objective is required';
    const goal: Goal = {
      objective: args.objective.trim(),
      status: 'active',
      budget: typeof args.budget === 'number' ? args.budget : undefined,
      createdAt: now().toISOString(),
    };
    host.state.goal = goal;
    return `OK: goal created\n${JSON.stringify(goal)}`;
  }

  if (name === 'get_goal') {
    return host.state.goal ? JSON.stringify(host.state.goal) : 'No goal is set.';
  }

  if (name === 'update_goal') {
    if (!host.state.goal) return 'ERROR: no goal is set';
    const status = args.status;
    if (status !== undefined) {
      if (!['active', 'paused', 'complete'].includes(String(status))) {
        return 'ERROR: status must be active|paused|complete';
      }
      host.state.goal.status = String(status) as Goal['status'];
    }
    if (typeof args.objective === 'string' && args.objective.trim()) {
      host.state.goal.objective = args.objective.trim();
    }
    return `OK: goal updated\n${JSON.stringify(host.state.goal)}`;
  }

  if (name === 'schedule_create') {
    const prompt = args.prompt;
    if (typeof prompt !== 'string' || !prompt.trim()) return 'ERROR: prompt is required';
    const atRaw = args.at;
    const at = typeof atRaw === 'string' ? new Date(atRaw) : new Date(Number(atRaw ?? NaN));
    if (Number.isNaN(at.getTime())) return 'ERROR: at must be an ISO timestamp or epoch ms';
    const schedule: Schedule = {
      id: `sch-${(host.state.schedules?.length ?? 0) + 1}`,
      prompt: prompt.trim(),
      at: at.toISOString(),
      repeatMs: typeof args.repeat_ms === 'number' ? args.repeat_ms : undefined,
      status: 'active',
    };
    host.state.schedules = [...(host.state.schedules ?? []), schedule];
    // The due-check driver lives in Server/index.ts (TRHA_SCHEDULE_TICK_MS):
    // it fires this record off the session it was persisted on, so a schedule
    // created here really does turn into a turn.
    return `OK: scheduled\n${JSON.stringify(schedule)}`;
  }

  if (name === 'schedule_list') {
    const list = host.state.schedules ?? [];
    return list.length ? list.map(s => JSON.stringify(s)).join('\n') : '(no schedules)';
  }

  if (name === 'schedule_update') {
    const id = typeof args.id === 'string' ? args.id : '';
    const s = (host.state.schedules ?? []).find(x => x.id === id);
    if (!s) return `ERROR: no schedule ${id}`;
    if (typeof args.prompt === 'string' && args.prompt.trim()) s.prompt = args.prompt.trim();
    if (typeof args.at === 'string') {
      const at = new Date(args.at);
      if (Number.isNaN(at.getTime())) return 'ERROR: bad at';
      s.at = at.toISOString();
    }
    if (typeof args.repeat_ms === 'number') s.repeatMs = args.repeat_ms;
    if (args.status === 'active' || args.status === 'cancelled') s.status = args.status;
    return `OK: updated\n${JSON.stringify(s)}`;
  }

  if (name === 'schedule_delete') {
    const id = typeof args.id === 'string' ? args.id : '';
    const before = host.state.schedules ?? [];
    const after = before.filter(s => s.id !== id);
    if (after.length === before.length) return `ERROR: no schedule ${id}`;
    host.state.schedules = after;
    return `OK: deleted ${id}`;
  }

  if (name === 'job_list') {
    const list = [...host.jobs.values()];
    if (list.length === 0) return '(no jobs)';
    return list.map(j =>
      `${j.id}\t${j.status}${j.exitCode !== undefined ? ` (${j.exitCode})` : ''}\t${j.command.slice(0, 80)}`,
    ).join('\n');
  }

  if (name === 'job_output') {
    const id = typeof args.id === 'string' ? args.id : '';
    const job = host.jobs.get(id);
    if (!job) return `ERROR: no job ${id}`;
    const out = job.output.join('');
    return `status: ${job.status}${job.exitCode !== undefined ? ` exit=${job.exitCode}` : ''}\n`
      + clip(out || '(no output yet)');
  }

  if (name === 'job_kill') {
    const id = typeof args.id === 'string' ? args.id : '';
    const job = host.jobs.get(id);
    if (!job) return `ERROR: no job ${id}`;
    if (job.status === 'running') {
      job.child?.kill('SIGTERM');
      job.status = 'exited';
      return `OK: killed ${id}`;
    }
    return `OK: ${id} already exited`;
  }

  if (name === 'skill') {
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
    if (body === null) return `ERROR: no skill "${wanted}" in ${dirs.join(', ')}`;
    return clip(body);
  }

  if (name === 'web_fetch') {
    // Registered at the bottom of this module; kept as a no-op marker so the
    // legacy chain still recognises the name if registration ever fails.
    return registeredWebFetch(args);
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
async function registeredWebFetch(args: Record<string, unknown>): Promise<string> {
  // `network: off` must mean *no egress*, not "no egress from subprocesses":
  // this tool runs `fetch` in the scheduler process, so without this guard an
  // agent answers "network off" with a plain HTTP GET.
  if (sandboxBlocksNetwork()) {
    return 'ERROR: network access is disabled by the sandbox policy (network: off). '
         + 'Enable it under /sandbox, or run outside the sandbox.';
  }
  const url = args.url;
  if (typeof url !== 'string' || !/^https?:\/\//i.test(url)) return 'ERROR: url must be http(s)';
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
    return clip(`HTTP ${res.status} ${type}\n${text}`);
  } catch (e) {
    return `ERROR: ${(e as Error).message}`;
  } finally {
    clearTimeout(timer);
  }
}

registerTool({
  name: 'web_fetch',
  plane: 'agent',
  handler: args => registeredWebFetch(args),
});
