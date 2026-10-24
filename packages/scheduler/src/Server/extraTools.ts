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
import { browserEvaluate, browserExtract, browserNavigate, browserScreenshot } from './browser.js';
import type { StandardToolHost, TeamTask } from './standardTools.js';

export interface Terminal {
  id: string;
  child: ChildProcessWithoutNullStreams;
  output: string;
  status: 'running' | 'exited';
  exitCode?: number;
}

export interface ExtraHost extends StandardToolHost {
  /** Session cwd, relative to (or inside) the workspace. */
  cwd: () => string;
  setCwd: (dir: string) => void;
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
}

export const EXTRA_TOOL_NAMES = [
  'working_directory', 'str_replace_editor', 'unified_edit',
  'terminal_open', 'terminal_send', 'terminal_read', 'terminal_signal', 'terminal_close', 'terminal_list',
  'wait_agent', 'spawn_teammate', 'team_task_get',
  'session_search', 'session_trace', 'session_event_read', 'session_event_search', 'session_event_trace',
  'create_worktree', 'load_workspace_dependencies', 'pwsh',
  'web_search', 'list_subagent_models', 'plugin_manager', 'cordis_inspect_list', 'cordis_inspect_query',
  'stagehand_navigate', 'stagehand_extract', 'stagehand_screenshot', 'stagehand_tabs', 'stagehand_act', 'stagehand_observe',
  'ralph',
] as const;

export function isExtraTool(name: string): boolean {
  return (EXTRA_TOOL_NAMES as readonly string[]).includes(name);
}

const clip = (s: string, cap = 20_000): string =>
  s.length <= cap ? s : `${s.slice(0, cap)}\n…(${s.length - cap} more chars)`;

const sh = (host: ExtraHost, cmd: string): Promise<{ code: number; out: string }> =>
  new Promise(resolve => {
    const child = spawn('bash', ['-lc', cmd], { cwd: host.cwd() });
    const out: string[] = [];
    child.stdout.on('data', (b: Buffer) => out.push(b.toString('utf8')));
    child.stderr.on('data', (b: Buffer) => out.push(b.toString('utf8')));
    child.on('error', e => resolve({ code: 127, out: e.message }));
    child.on('exit', code => resolve({ code: code ?? -1, out: out.join('') }));
  });

export async function runExtraTool(
  name: string,
  args: Record<string, unknown>,
  host: ExtraHost,
): Promise<string | null> {
  // ── working directory ────────────────────────────────────────────────
  if (name === 'working_directory') {
    if (typeof args.path === 'string' && args.path.trim()) {
      const target = path.resolve(host.cwd(), args.path.trim());
      try {
        const s = await stat(target);
        if (!s.isDirectory()) return `ERROR: not a directory: ${target}`;
      } catch {
        return `ERROR: no such directory: ${target}`;
      }
      // A cwd outside the workspace would let fs tools escape; clamp it.
      const root = path.resolve(host.workspace);
      if (target !== root && !target.startsWith(root + path.sep)) {
        return `ERROR: working directory must stay inside ${root}`;
      }
      host.setCwd(target);
      return `OK: cwd is now ${target}`;
    }
    return host.cwd();
  }

  // ── editor-style file ops (dsh's str_replace_editor / unified_edit) ──
  if (name === 'str_replace_editor' || name === 'unified_edit') {
    const command = typeof args.command === 'string' ? args.command : 'view';
    const rawPath = typeof args.path === 'string' ? args.path : '';
    if (!rawPath) return 'ERROR: path is required';
    const file = path.resolve(host.cwd(), rawPath);
    if (command === 'view') {
      try {
        const text = await readFile(file, 'utf8');
        const num = text.split('\n').map((l, i) => `${i + 1}\t${l}`).join('\n');
        return clip(num);
      } catch (e) {
        // viewing a directory lists it
        try {
          const entries = await readdir(file, { withFileTypes: true });
          return entries.map(e2 => `${e2.isDirectory() ? 'd' : 'f'} ${e2.name}`).join('\n');
        } catch {
          return `ERROR: ${(e as Error).message}`;
        }
      }
    }
    if (command === 'create') {
      const body = typeof args.file_text === 'string' ? args.file_text : '';
      await mkdir(path.dirname(file), { recursive: true });
      await writeFile(file, body, 'utf8');
      return `OK: created ${file} (${body.length} chars)`;
    }
    if (command === 'str_replace') {
      const oldStr = typeof args.old_str === 'string' ? args.old_str : '';
      const newStr = typeof args.new_str === 'string' ? args.new_str : '';
      if (!oldStr) return 'ERROR: old_str is required';
      let text: string;
      try { text = await readFile(file, 'utf8'); } catch (e) { return `ERROR: ${(e as Error).message}`; }
      const count = text.split(oldStr).length - 1;
      if (count === 0) return 'ERROR: old_str not found';
      if (count > 1) return `ERROR: old_str appears ${count} times; make it unique`;
      await writeFile(file, text.replace(oldStr, newStr), 'utf8');
      return `OK: replaced 1 occurrence in ${file}`;
    }
    if (command === 'insert') {
      const line = typeof args.insert_line === 'number' ? args.insert_line : 0;
      const text = typeof args.new_str === 'string' ? args.new_str : '';
      let body: string;
      try { body = await readFile(file, 'utf8'); } catch (e) { return `ERROR: ${(e as Error).message}`; }
      const lines = body.split('\n');
      const at = Math.max(0, Math.min(lines.length, line));
      lines.splice(at, 0, ...text.split('\n'));
      await writeFile(file, lines.join('\n'), 'utf8');
      return `OK: inserted ${text.split('\n').length} line(s) at ${at + 1}`;
    }
    return `ERROR: unknown command "${command}" (view|create|str_replace|insert)`;
  }

  // ── persistent terminals ─────────────────────────────────────────────
  if (name === 'terminal_open') {
    const id = `term-${host.terminals.size + 1}`;
    const child = spawn('bash', ['-l'], {
      cwd: host.cwd(), env: { ...process.env, PS1: '' }, stdio: ['pipe', 'pipe', 'pipe'],
    }) as ChildProcessWithoutNullStreams;
    const term: Terminal = { id, child, output: '', status: 'running' };
    const push = (b: Buffer): void => {
      term.output += b.toString('utf8');
      if (term.output.length > 200_000) term.output = term.output.slice(-200_000);
    };
    child.stdout.on('data', push);
    child.stderr.on('data', push);
    child.on('exit', code => { term.status = 'exited'; term.exitCode = code ?? -1; });
    host.terminals.set(id, term);
    return `OK: ${id} (shell pid ${child.pid ?? '?'})`;
  }
  if (name === 'terminal_send') {
    const id = typeof args.id === 'string' ? args.id : '';
    const input = typeof args.input === 'string' ? args.input : '';
    const term = host.terminals.get(id);
    if (!term) return `ERROR: no terminal ${id}`;
    if (term.status !== 'running') return `ERROR: ${id} has exited`;
    term.child.stdin.write(input.endsWith('\n') ? input : `${input}\n`);
    return `OK: sent ${input.length} chars to ${id}`;
  }
  if (name === 'terminal_read') {
    const id = typeof args.id === 'string' ? args.id : '';
    const term = host.terminals.get(id);
    if (!term) return `ERROR: no terminal ${id}`;
    const since = typeof args.since === 'number' ? args.since : 0;
    const chunk = term.output.slice(since);
    return clip(`status: ${term.status}${term.exitCode !== undefined ? ` exit=${term.exitCode}` : ''}\n${chunk || '(no output yet)'}`);
  }
  if (name === 'terminal_signal') {
    const id = typeof args.id === 'string' ? args.id : '';
    const sig = typeof args.signal === 'string' ? args.signal : 'SIGINT';
    const term = host.terminals.get(id);
    if (!term) return `ERROR: no terminal ${id}`;
    term.child.kill(sig as NodeJS.Signals);
    return `OK: sent ${sig} to ${id}`;
  }
  if (name === 'terminal_close') {
    const id = typeof args.id === 'string' ? args.id : '';
    const term = host.terminals.get(id);
    if (!term) return `ERROR: no terminal ${id}`;
    term.child.kill('SIGTERM');
    host.terminals.delete(id);
    return `OK: closed ${id}`;
  }
  if (name === 'terminal_list') {
    if (host.terminals.size === 0) return '(no terminals)';
    return [...host.terminals.values()]
      .map(t => `${t.id}\t${t.status}\t${t.output.length} chars`).join('\n');
  }

  // ── agents ───────────────────────────────────────────────────────────
  if (name === 'wait_agent') {
    const id = typeof args.id === 'string' ? args.id : '';
    const timeout = typeof args.timeout_ms === 'number' ? args.timeout_ms : 30_000;
    if (!id) return 'ERROR: id is required';
    const deadline = Date.now() + Math.min(timeout, 120_000);
    while (Date.now() < deadline) {
      const ref = host.agents?.list().find(a => a.id === id);
      if (!ref) return `ERROR: no agent ${id}`;
      if (!ref.busy) return `OK: ${id} is idle (${ref.messages} msgs)`;
      await new Promise(r => setTimeout(r, 100));
    }
    return `TIMEOUT: ${id} still busy after ${timeout} ms`;
  }
  if (name === 'spawn_teammate') {
    if (!host.agents) return 'ERROR: subagents are not available in this host';
    const task = typeof args.task === 'string' ? args.task : '';
    if (!task.trim()) return 'ERROR: task is required';
    const teammate = typeof args.name === 'string' ? args.name : 'teammate';
    const r = await host.agents.spawn(task, teammate);
    // A teammate is also a team-list entry, so the shared list names it.
    const tasks = host.agents.teamTasks();
    const entry: TeamTask = { id: `t${tasks.length + 1}`, subject: `teammate ${teammate}: ${task.slice(0, 60)}`, status: 'in_progress', assignee: r.id };
    host.agents.setTeamTasks([...tasks, entry]);
    return `teammate ${r.id} finished:\n${clip(r.reply)}`;
  }
  if (name === 'team_task_get') {
    if (!host.agents) return 'ERROR: team tasks are not available in this host';
    const id = typeof args.id === 'string' ? args.id : '';
    const t = host.agents.teamTasks().find(x => x.id === id);
    return t ? JSON.stringify(t) : `ERROR: no team task ${id}`;
  }

  // ── sessions ─────────────────────────────────────────────────────────
  if (name === 'session_search') {
    const query = typeof args.query === 'string' ? args.query.trim() : '';
    if (!query) return 'ERROR: query is required';
    const limit = typeof args.limit === 'number' ? args.limit : 20;
    const sessions = host.allSessions?.() ?? [];
    const hits: string[] = [];
    for (const s of sessions) {
      for (const [i, m] of s.messages.entries()) {
        if (typeof m.content === 'string' && m.content.includes(query)) {
          hits.push(`${s.id}\t#${i}\t${m.role}\t${m.content.slice(Math.max(0, m.content.indexOf(query) - 40), m.content.indexOf(query) + 80)}`);
          break;
        }
      }
      if (hits.length >= limit) break;
    }
    return hits.length ? clip(hits.join('\n')) : `(no session contains "${query}")`;
  }
  if (name === 'session_trace') {
    const target = typeof args.sessionId === 'string' ? args.sessionId : host.sessionId;
    const s = (host.allSessions?.() ?? []).find(x => x.id === target);
    if (!s) return `ERROR: no session ${target}`;
    return clip(s.messages.map((m, i) => `#${i}\t${m.role}\t${(m.content ?? '').slice(0, 120).replace(/\n/g, ' ')}`).join('\n'));
  }
  if (name === 'session_event_read' || name === 'session_event_search' || name === 'session_event_trace') {
    const target = typeof args.sessionId === 'string' ? args.sessionId : host.sessionId;
    const events = (await host.kernelEvents?.(target)) ?? [];
    if (events.length === 0) return '(no kernel events; kernel unreachable or session unknown)';
    if (name === 'session_event_read') {
      const limit = typeof args.limit === 'number' ? args.limit : 20;
      return clip(events.slice(-limit).map(e => JSON.stringify(e)).join('\n'));
    }
    if (name === 'session_event_search') {
      const needle = typeof args.query === 'string' ? args.query : '';
      if (!needle) return 'ERROR: query is required';
      const hits = events.filter(e => JSON.stringify(e).includes(needle));
      return hits.length ? clip(hits.map(e => JSON.stringify(e)).join('\n')) : `(no event contains "${needle}")`;
    }
    const counts = new Map<string, number>();
    for (const e of events) {
      const k = String((e as { kind?: unknown }).kind ?? '?');
      counts.set(k, (counts.get(k) ?? 0) + 1);
    }
    return [...counts.entries()].map(([k, n]) => `${k}: ${n}`).join('\n') + `\ntotal: ${events.length}`;
  }

  // ── repo / env ───────────────────────────────────────────────────────
  if (name === 'create_worktree') {
    const target = typeof args.path === 'string' ? args.path : '';
    const branch = typeof args.branch === 'string' ? args.branch : `wt-${Date.now().toString(36)}`;
    if (!target) return 'ERROR: path is required';
    const r = await sh(host, `git worktree add ${JSON.stringify(path.resolve(host.cwd(), target))} -b ${JSON.stringify(branch)}`);
    return r.code === 0 ? `OK: worktree at ${target} on ${branch}\n${clip(r.out)}` : `ERROR: ${clip(r.out)}`;
  }
  if (name === 'load_workspace_dependencies') {
    const dir = host.cwd();
    const has = async (f: string): Promise<boolean> => {
      try { await stat(path.join(dir, f)); return true; } catch { return false; }
    };
    let cmd = '';
    if (await has('pnpm-lock.yaml')) cmd = 'pnpm install';
    else if (await has('package-lock.json') || await has('package.json')) cmd = 'npm install';
    else if (await has('Cargo.toml')) cmd = 'cargo fetch';
    else if (await has('stack.yaml')) cmd = 'stack build --only-dependencies';
    else if (await has('cabal.project')) cmd = 'cabal build --only-dependencies';
    else return 'ERROR: no recognised dependency manifest in the working directory';
    const r = await sh(host, cmd);
    return clip(`$ ${cmd}\nexit ${r.code}\n${r.out}`);
  }
  if (name === 'pwsh') {
    const cmd = typeof args.command === 'string' ? args.command : '';
    if (!cmd) return 'ERROR: command is required';
    const r = await new Promise<{ code: number; out: string }>(resolve => {
      const child = spawn('pwsh', ['-NoLogo', '-Command', cmd], { cwd: host.cwd() });
      const out: string[] = [];
      child.stdout.on('data', (b: Buffer) => out.push(b.toString('utf8')));
      child.stderr.on('data', (b: Buffer) => out.push(b.toString('utf8')));
      child.on('error', e => resolve({ code: 127, out: e.message }));
      child.on('exit', code => resolve({ code: code ?? -1, out: out.join('') }));
    });
    if (r.code === 127) return `ERROR: pwsh is not installed (${r.out})`;
    return clip(`exit ${r.code}\n${r.out}`);
  }

  // ── search / models / plugins ────────────────────────────────────────
  if (name === 'web_search') {
    const query = typeof args.query === 'string' ? args.query.trim() : '';
    if (!query) return 'ERROR: query is required';
    const searx = process.env.TRHA_SEARX_URL;
    const url = searx
      ? `${searx.replace(/\/$/, '')}/search?q=${encodeURIComponent(query)}&format=json`
      : `https://html.duckduckgo.com/html/?q=${encodeURIComponent(query)}`;
    try {
      const res = await fetch(url, { headers: { 'User-Agent': 'trha/1.0' } });
      const body = await res.text();
      if (searx) {
        const data = JSON.parse(body) as { results?: Array<{ title?: string; url?: string; content?: string }> };
        const rows = (data.results ?? []).slice(0, 10)
          .map(r => `${r.title ?? ''}\n${r.url ?? ''}\n${(r.content ?? '').slice(0, 200)}`);
        return rows.length ? clip(rows.join('\n\n')) : '(no results)';
      }
      const stripped = body
        .replace(/<script[\s\S]*?<\/script>/gi, ' ')
        .replace(/<[^>]+>/g, ' ')
        .replace(/&amp;/g, '&')
        .replace(/\s+/g, ' ')
        .trim();
      return clip(`HTTP ${res.status}\n${stripped.slice(0, 4000)}`);
    } catch (e) {
      return `ERROR: ${(e as Error).message}`;
    }
  }
  if (name === 'list_subagent_models') {
    const models = host.models?.() ?? [];
    return models.length ? models.map(m => `${m.name}\t${m.description ?? ''}`).join('\n') : '(no models configured)';
  }
  if (name === 'plugin_manager' || name === 'cordis_inspect_list') {
    if (!host.plugins) return 'ERROR: plugin introspection is not available in this host';
    const list = host.plugins.list();
    return list.length ? list.map(p => `${p.name}\t${p.enabled ? 'enabled' : 'disabled'}\t${p.hooks.join(',')}`).join('\n') : '(no plugins)';
  }
  if (name === 'cordis_inspect_query') {
    if (!host.plugins) return 'ERROR: plugin introspection is not available in this host';
    const target = typeof args.name === 'string' ? args.name : '';
    if (!target) return 'ERROR: name is required';
    const info = host.plugins.inspect(target);
    return info === undefined ? `ERROR: no plugin ${target}` : clip(JSON.stringify(info, null, 2));
  }
  if (name === 'plugin_market') {
    const source = process.env.TRHA_PLUGIN_MARKET;
    if (!source) return 'ERROR: plugin_market needs TRHA_PLUGIN_MARKET (URL or JSON file)';
    try {
      const raw = /^https?:/i.test(source)
        ? await (await fetch(source)).text()
        : await readFile(source, 'utf8');
      const parsed = JSON.parse(raw) as Array<{ name?: string; version?: string; description?: string }> | { plugins?: unknown[] };
      const list = Array.isArray(parsed) ? parsed : (parsed.plugins ?? []) as Array<{ name?: string; version?: string; description?: string }>;
      return list.length
        ? clip(list.map(p => `${p.name ?? '?'}\t${p.version ?? ''}\t${p.description ?? ''}`).join('\n'))
        : '(market is empty)';
    } catch (e) {
      return `ERROR: ${(e as Error).message}`;
    }
  }

  // ── stagehand aliases (same CDP browser as browser_*) ────────────────
  if (name === 'stagehand_navigate') {
    const url = typeof args.url === 'string' ? args.url : '';
    if (!url) return 'ERROR: url is required';
    try {
      const page = await browserNavigate(url);
      return clip(`title: ${page.title}\nurl: ${page.url}\n\n${page.text}`);
    } catch (e) { return `ERROR: ${(e as Error).message}`; }
  }
  if (name === 'stagehand_extract') {
    try { return clip(await browserExtract(typeof args.selector === 'string' ? args.selector : undefined)); }
    catch (e) { return `ERROR: ${(e as Error).message}`; }
  }
  if (name === 'stagehand_screenshot') {
    try { return `OK: screenshot -> ${await browserScreenshot(host.workspace, typeof args.path === 'string' ? args.path : undefined)}`; }
    catch (e) { return `ERROR: ${(e as Error).message}`; }
  }
  if (name === 'stagehand_tabs') {
    try {
      // Ask the page, don't navigate: 'about:blank' is not http(s) and would be
      // rejected by the navigate guard.
      const href = await browserEvaluate('location.href');
      const title = await browserEvaluate('document.title');
      return `single-tab mode; current url: ${href}\ntitle: ${title}`;
    } catch (e) { return `ERROR: ${(e as Error).message}`; }
  }
  if (name === 'stagehand_observe') {
    // No planner: report the interactive elements, which is what an observe
    // step needs to hand back to a model.
    try {
      const text = await browserExtract('a,button,input,select,textarea');
      return clip(text || '(no interactive elements)');
    } catch (e) { return `ERROR: ${(e as Error).message}`; }
  }
  if (name === 'stagehand_act') {
    const action = typeof args.action === 'string' ? args.action : '';
    const selector = typeof args.selector === 'string' ? args.selector : '';
    const value = typeof args.value === 'string' ? args.value : '';
    if (!action || !selector) return 'ERROR: action and selector are required';
    try {
      // Drive the page through the same browser session via a tiny JS shim.
      if (typeof args.url === 'string') await browserNavigate(args.url);
      const js = action === 'click'
        ? `(() => { const el = document.querySelector(${JSON.stringify(selector)}); if (!el) return 'not found'; el.click(); return 'clicked'; })()`
        : action === 'type'
          // A form control takes `value`, anything else takes textContent; both
          // get an input event so frameworks notice either way.
          ? `(() => { const el = document.querySelector(${JSON.stringify(selector)}); if (!el) return 'not found';`
            + ` if ('value' in el) { el.value = ${JSON.stringify(value)}; } else { el.textContent = ${JSON.stringify(value)}; }`
            + ` el.dispatchEvent(new Event('input', { bubbles: true })); return 'typed'; })()`
          : null;
      if (!js) return `ERROR: unsupported action "${action}" (click|type)`;
      return await browserEvaluate(js);
    } catch (e) { return `ERROR: ${(e as Error).message}`; }
  }

  // ── ralph loop ───────────────────────────────────────────────────────
  if (name === 'ralph') {
    const objective = typeof args.objective === 'string' ? args.objective.trim() : '';
    if (!objective) return 'ERROR: objective is required';
    const rounds = typeof args.rounds === 'number' ? Math.max(1, Math.min(10, args.rounds)) : 3;
    if (!host.spawnFresh) return 'ERROR: ralph needs a subagent host';
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
  }

  return null;
}
