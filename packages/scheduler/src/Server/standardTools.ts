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
import { mkdir, readdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';

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
  status: 'active' | 'cancelled';
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

export interface StandardToolHost {
  workspace: string;
  /** Mutable session slice; the caller persists it after the tool runs. */
  state: { todos?: Todo[]; goal?: Goal | null; schedules?: Schedule[] };
  /** Jobs are shared per scheduler process, keyed by session. */
  jobs: Map<string, JobRecord>;
  sessionId: string;
  now?: () => Date;
}

const MAX_OUTPUT_CHARS = 20_000;
const MAX_JOB_OUTPUT = 200_000;

const clip = (s: string, cap = MAX_OUTPUT_CHARS): string =>
  s.length <= cap ? s : `${s.slice(0, cap)}\n…(${s.length - cap} more chars)`;

export const STANDARD_TOOL_NAMES = [
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
  const child = spawn('bash', ['-lc', command], { cwd: host.workspace }) as ChildProcessWithoutNullStreams;
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
  .replace(/<\/(p|div|li|tr|h[1-6]|br)>/gi, '\n')
  .replace(/<br\s*\/?>/gi, '\n')
  .replace(/<[^>]+>/g, ' ')
  .replace(/&nbsp;/g, ' ')
  .replace(/&lt;/g, '<')
  .replace(/&gt;/g, '>')
  .replace(/&amp;/g, '&')
  .replace(/[ \t]+/g, ' ')
  .replace(/\n{3,}/g, '\n\n')
  .trim();

/** Run one standard tool. Returns null when the name is not one of them. */
export async function runStandardTool(
  name: string,
  args: Record<string, unknown>,
  host: StandardToolHost,
): Promise<string | null> {
  const now = host.now ?? (() => new Date());

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
    // The due-check driver is not part of this port: the record is real, the
    // firing is not (documented), so this never silently spends tokens.
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
    const dir = process.env.TRHA_SKILLS_DIR ?? path.join(host.workspace, '.trha', 'skills');
    const wanted = typeof args.name === 'string' ? args.name : '';
    if (!wanted) {
      let names: string[] = [];
      try {
        names = (await readdir(dir)).filter(f => f.endsWith('.md')).map(f => f.replace(/\.md$/, ''));
      } catch {
        return `(no skills; put markdown files in ${dir})`;
      }
      return names.length ? names.sort().join('\n') : `(no skills in ${dir})`;
    }
    const file = path.join(dir, `${wanted.replace(/[^A-Za-z0-9._-]/g, '_')}.md`);
    try {
      return clip(await readFile(file, 'utf8'));
    } catch {
      return `ERROR: no skill "${wanted}" in ${dir}`;
    }
  }

  if (name === 'web_fetch') {
    const url = args.url;
    if (typeof url !== 'string' || !/^https?:\/\//i.test(url)) return 'ERROR: url must be http(s)';
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), 15_000);
    try {
      const res = await fetch(url, { signal: ctrl.signal, headers: { 'User-Agent': 'trha/1.0' } });
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

  return null;
}

/** Persist a skill file (used by the skills round-trip test and by tooling). */
export async function writeSkill(dir: string, name: string, body: string): Promise<void> {
  await mkdir(dir, { recursive: true });
  await writeFile(path.join(dir, `${name}.md`), body, 'utf8');
}
