// Remaining dsh tools: editor ops, persistent terminals, session queries,
// ralph, search/models/plugins, and the stagehand aliases.

import { describe, it, expect, beforeEach, afterEach, afterAll } from 'vitest';
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import http from 'node:http';
import type { AddressInfo } from 'node:net';
import path from 'node:path';
import { runExtraTool, type ExtraHost, type Terminal } from '../src/Server/extraTools.js';
import { browserCloseAll } from '../src/Server/browser.js';

let dir = '';
let host: ExtraHost;

function makeHost(overrides: Partial<ExtraHost> = {}): ExtraHost {
  let cwd = dir;
  return {
    workspace: dir,
    state: {},
    jobs: new Map(),
    sessionId: 's1',
    cwd: () => cwd,
    setCwd: (d: string) => { cwd = d; },
    terminals: new Map<string, Terminal>(),
    ...overrides,
  };
}

beforeEach(async () => {
  dir = await mkdtemp(path.join(tmpdir(), 'trha-extra-'));
  host = makeHost();
});
afterEach(async () => { await rm(dir, { recursive: true, force: true }); });

describe('editor + working directory', () => {
  it('creates, views, replaces and inserts', async () => {
    expect(await runExtraTool('str_replace_editor', { command: 'create', path: 'a.txt', file_text: 'one\ntwo\n' }, host))
      .toMatch(/created/);
    expect(await runExtraTool('str_replace_editor', { command: 'view', path: 'a.txt' }, host)).toContain('1\tone');
    await runExtraTool('str_replace_editor', { command: 'str_replace', path: 'a.txt', old_str: 'two', new_str: 'TWO' }, host);
    expect(await readFile(path.join(dir, 'a.txt'), 'utf8')).toBe('one\nTWO\n');
    await runExtraTool('str_replace_editor', { command: 'insert', path: 'a.txt', insert_line: 1, new_str: 'mid' }, host);
    expect(await readFile(path.join(dir, 'a.txt'), 'utf8')).toBe('one\nmid\nTWO\n');
    // ambiguous replace is refused
    await runExtraTool('str_replace_editor', { command: 'create', path: 'dup.txt', file_text: 'x x' }, host);
    expect(await runExtraTool('str_replace_editor', { command: 'str_replace', path: 'dup.txt', old_str: 'x', new_str: 'y' }, host))
      .toMatch(/appears 2 times/);
  });

  it('switches cwd inside the workspace and refuses to leave it', async () => {
    await mkdir(path.join(dir, 'sub'));
    expect(await runExtraTool('working_directory', {}, host)).toBe(dir);
    expect(await runExtraTool('working_directory', { path: 'sub' }, host)).toBe(`OK: cwd is now ${path.join(dir, 'sub')}`);
    expect(await runExtraTool('working_directory', {}, host)).toBe(path.join(dir, 'sub'));
    expect(await runExtraTool('working_directory', { path: '/etc' }, host)).toMatch(/must stay inside/);
    expect(await runExtraTool('working_directory', { path: 'nope' }, host)).toMatch(/no such directory/);
  });
});

describe('persistent terminals', () => {
  it('opens, runs a command, reads it, lists and closes', async () => {
    const opened = await runExtraTool('terminal_open', {}, host);
    const id = /term-1/.exec(opened ?? '')?.[0];
    expect(id).toBeTruthy();
    await runExtraTool('terminal_send', { id, input: 'echo term-ok' }, host);
    // bash -l startup races the fixed sleep under full-suite load; poll instead
    let read = '';
    for (let i = 0; i < 30 && !read.includes('term-ok'); i++) {
      await new Promise(r => setTimeout(r, 100));
      read = await runExtraTool('terminal_read', { id }, host);
    }
    expect(read).toContain('term-ok');
    expect(await runExtraTool('terminal_list', {}, host)).toContain(id!);
    expect(await runExtraTool('terminal_close', { id }, host)).toMatch(/closed/);
    expect(host.terminals.size).toBe(0);
    expect(await runExtraTool('terminal_read', { id }, host)).toMatch(/no terminal/);
  });
});

describe('session queries', () => {
  const agents = {
    spawn: async () => ({ id: 's1#x', reply: '' }),
    list: () => [{ id: 's1', messages: 2 }, { id: 'busy-1', busy: true, messages: 0 }],
    send: async () => ({ delivered: true }),
    interrupt: () => false,
    teamTasks: () => [{ id: 't1', subject: 'one', status: 'pending' as const }],
    setTeamTasks: () => {},
  };

  it('waits for an idle agent and reports unknown ones', async () => {
    const h = makeHost({ agents });
    expect(await runExtraTool('wait_agent', { id: 's1' }, h)).toMatch(/idle/);
    expect(await runExtraTool('wait_agent', { id: 'nope' }, h)).toMatch(/no agent/);
    expect(await runExtraTool('wait_agent', { id: 'busy-1', timeout_ms: 150 }, h)).toMatch(/TIMEOUT/);
  });

  it('reads one team task', async () => {
    const h = makeHost({ agents });
    expect(await runExtraTool('team_task_get', { id: 't1' }, h)).toContain('"subject":"one"');
    expect(await runExtraTool('team_task_get', { id: 't9' }, h)).toMatch(/no team task/);
  });

  it('searches transcripts and traces one', async () => {
    const allSessions = () => [
      { id: 'a', messages: [{ role: 'user', content: 'hello needle' }, { role: 'assistant', content: 'ok' }] },
      { id: 'b', messages: [{ role: 'user', content: 'nothing' }] },
    ];
    const h = makeHost({ allSessions });
    const hits = await runExtraTool('session_search', { query: 'needle' }, h);
    expect(hits).toContain('a');
    expect(hits).not.toContain('\tb\t');
    expect(await runExtraTool('session_search', { query: 'zzz' }, h)).toMatch(/no session/);
    expect(await runExtraTool('session_trace', { sessionId: 'a' }, h)).toContain('#0\tuser');
    expect(await runExtraTool('session_trace', { sessionId: 'zzz' }, h)).toMatch(/no session/);
  });

  it('reads, searches and traces kernel events', async () => {
    const kernelEvents = async () => [
      { kind: 'user_message', text: 'hi' },
      { kind: 'assistant_message', text: 'hello' },
      { kind: 'agent_state', agentState: { state: 'processing' } },
    ];
    const h = makeHost({ kernelEvents });
    expect(await runExtraTool('session_event_read', { limit: 1 }, h)).toContain('agent_state');
    expect(await runExtraTool('session_event_search', { query: 'hello' }, h)).toContain('assistant_message');
    const trace = await runExtraTool('session_event_trace', {}, h);
    expect(trace).toContain('user_message: 1');
    expect(trace).toContain('total: 3');
  });
});

describe('models, plugins, search', () => {
  it('lists models and plugins', async () => {
    const h = makeHost({
      models: () => [{ name: 'deepseek-flash', description: 'flash' }],
      plugins: {
        list: () => [{ name: 'demo', enabled: true, hooks: ['onInit'] }],
        inspect: (n: string) => (n === 'demo' ? { name: 'demo', hooks: ['onInit'] } : undefined),
      },
    });
    expect(await runExtraTool('list_subagent_models', {}, h)).toContain('deepseek-flash');
    expect(await runExtraTool('plugin_manager', {}, h)).toContain('demo');
    expect(await runExtraTool('cordis_inspect_query', { name: 'demo' }, h)).toContain('onInit');
    expect(await runExtraTool('cordis_inspect_query', { name: 'x' }, h)).toMatch(/no plugin/);
  });

  it('queries SearXNG when configured', async () => {
    const srv = http.createServer((_q, res) => {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ results: [{ title: 'T', url: 'https://e.x', content: 'C' }] }));
    });
    await new Promise<void>(r => srv.listen(0, '127.0.0.1', r));
    process.env.TRHA_SEARX_URL = `http://127.0.0.1:${(srv.address() as AddressInfo).port}`;
    const out = await runExtraTool('web_search', { query: 'anything' }, host);
    delete process.env.TRHA_SEARX_URL;
    srv.close();
    expect(out).toContain('https://e.x');
  });

  it('explains a missing plugin market instead of failing silently', async () => {
    delete process.env.TRHA_PLUGIN_MARKET;
    expect(await runExtraTool('plugin_market', {}, host)).toMatch(/needs TRHA_PLUGIN_MARKET/);
  });
});

describe('ralph loop', () => {
  it('runs fresh children until STATUS: DONE', async () => {
    const calls: string[] = [];
    let round = 0;
    const h = makeHost({
      spawnFresh: async (task, name) => {
        calls.push(name ?? task.slice(0, 10));
        round += 1;
        return { id: `s1#ralph-${round}`, reply: round >= 2 ? 'did it\nSTATUS: DONE' : 'progress\nSTATUS: CONTINUE' };
      },
    });
    const out = await runExtraTool('ralph', { objective: 'finish', rounds: 5 }, h);
    expect(round).toBe(2);                       // stopped at DONE, not at the cap
    expect(out).toContain('STATUS: DONE');
    expect(calls).toEqual(['ralph-1', 'ralph-2']);
  });
});

describe('stagehand aliases', () => {
  let srv: http.Server;
  let url = '';
  beforeAll(async () => {
    srv = http.createServer((_q, res) => {
      res.writeHead(200, { 'content-type': 'text/html' });
      res.end('<html><head><title>SH</title></head><body><button id="b">Press</button><div id="o">initial</div></body></html>');
    });
    await new Promise<void>(r => srv.listen(0, '127.0.0.1', r));
    url = `http://127.0.0.1:${(srv.address() as AddressInfo).port}/`;
  });
  afterAll(() => { srv.close(); });
  afterEach(async () => { await browserCloseAll(); });

  it('navigates with the stagehand name', async () => {
    const out = await runExtraTool('stagehand_navigate', { url }, host);
    expect(out).toContain('SH');
    expect(out).toContain('Press');
  });

  it('observes interactive elements and acts on one', async () => {
    await runExtraTool('stagehand_navigate', { url }, host);
    expect(await runExtraTool('stagehand_observe', {}, host)).toContain('Press');
    const clicked = await runExtraTool('stagehand_act', { action: 'click', selector: '#b' }, host);
    expect(clicked).toBe('clicked');
    const typed = await runExtraTool('stagehand_act', { action: 'type', selector: '#o', value: 'typed!' }, host);
    expect(typed).toBe('typed');
    expect(await runExtraTool('stagehand_extract', { selector: '#o' }, host)).toBe('typed!');
  });
});

describe('remaining branches', () => {
  it('unified_edit behaves like str_replace_editor', async () => {
    expect(await runExtraTool('unified_edit', { command: 'create', path: 'u.txt', file_text: 'a' }, host)).toMatch(/created/);
    expect(await runExtraTool('unified_edit', { command: 'view', path: 'u.txt' }, host)).toContain('a');
    expect(await runExtraTool('unified_edit', { command: 'nope', path: 'u.txt' }, host)).toMatch(/unknown command/);
  });

  it('terminal errors name the missing terminal', async () => {
    expect(await runExtraTool('terminal_send', { id: 'term-9', input: 'x' }, host)).toMatch(/no terminal/);
    expect(await runExtraTool('terminal_signal', { id: 'term-9' }, host)).toMatch(/no terminal/);
    expect(await runExtraTool('terminal_close', { id: 'term-9' }, host)).toMatch(/no terminal/);
    expect(await runExtraTool('terminal_list', {}, host)).toBe('(no terminals)');
  });

  it('spawn_teammate records the teammate on the shared list', async () => {
    let tasks: import('../src/Server/standardTools.js').TeamTask[] = [];
    const h = makeHost({
      agents: {
        spawn: async () => ({ id: 's1#tm-1', reply: 'did it' }),
        list: () => [],
        send: async () => ({ delivered: true }),
        interrupt: () => false,
        teamTasks: () => tasks,
        setTeamTasks: t => { tasks = t; },
      },
    });
    const out = await runExtraTool('spawn_teammate', { task: 'review the diff', name: 'reviewer' }, h);
    expect(out).toContain('did it');
    expect(tasks[0]?.assignee).toBe('s1#tm-1');
    expect(tasks[0]?.status).toBe('in_progress');
  });

  it('ralph stops on BLOCKED as well as DONE', async () => {
    let n = 0;
    const h = makeHost({
      spawnFresh: async () => { n += 1; return { id: `r${n}`, reply: 'STATUS: BLOCKED: no network' }; },
    });
    const out = await runExtraTool('ralph', { objective: 'x', rounds: 4 }, h);
    expect(n).toBe(1);
    expect(out).toContain('BLOCKED');
  });

  it('pwsh reports a missing binary clearly', async () => {
    const out = await runExtraTool('pwsh', { command: 'echo hi' }, host);
    expect(out).toMatch(/^ERROR: neither pwsh nor powershell\.exe is installed|^exit 0/);
  });

  it('session events degrade when the kernel is unreachable', async () => {
    const h = makeHost();
    expect(await runExtraTool('session_event_read', {}, h)).toMatch(/no kernel events/);
  });

  it('reads the plugin market from a JSON file', async () => {
    const file = path.join(dir, 'market.json');
    await writeFile(file, JSON.stringify([{ name: 'p1', version: '1.0.0', description: 'first' }]));
    process.env.TRHA_PLUGIN_MARKET = file;
    const out = await runExtraTool('plugin_market', {}, host);
    delete process.env.TRHA_PLUGIN_MARKET;
    expect(out).toContain('p1');
  });

  it('creates a real git worktree', async () => {
    const repo = path.join(dir, 'repo');
    await mkdir(repo);
    const git = async (cmd: string): Promise<void> => {
      const { execFile } = await import('node:child_process');
      await new Promise<void>((resolve, reject) => {
        execFile('bash', ['-lc', `cd ${repo} && ${cmd}`], err => (err ? reject(err) : resolve()));
      });
    };
    await git('git init -q && git config user.email t@e.x && git config user.name t && touch f && git add f && git commit -qm init');
    const h = makeHost({ cwd: () => repo, setCwd: () => {} });
    const out = await runExtraTool('create_worktree', { path: '../wt', branch: 'feature' }, h);
    expect(out).toMatch(/^OK: worktree/);
  });

  it('loads workspace dependencies for a manifest it knows', async () => {
    const proj = path.join(dir, 'proj');
    await mkdir(proj);
    await writeFile(path.join(proj, 'package.json'), JSON.stringify({ name: 'x', version: '1.0.0' }));
    const h = makeHost({ cwd: () => proj, setCwd: () => {} });
    const out = await runExtraTool('load_workspace_dependencies', {}, h);
    expect(out).toMatch(/\$ npm install/);
  });

  it('rejects an unknown stagehand action', async () => {
    const out = await runExtraTool('stagehand_act', { action: 'hover', selector: '#x' }, host);
    expect(out).toMatch(/unsupported action/);
  });
});

describe('closing the remaining branches', () => {
  it('event search reports a miss; trace defaults to the current session', async () => {
    const h = makeHost({
      kernelEvents: async () => [{ kind: 'user_message', text: 'hi' }],
      allSessions: () => [{ id: 's1', messages: [{ role: 'user', content: 'hi' }] }],
    });
    expect(await runExtraTool('session_event_search', { query: 'zzz' }, h)).toMatch(/no event contains/);
    expect(await runExtraTool('session_trace', {}, h)).toContain('#0');
  });

  it('view on a directory lists entries', async () => {
    await mkdir(path.join(dir, 'd'));
    await writeFile(path.join(dir, 'd', 'f.txt'), 'x');
    const out = await runExtraTool('str_replace_editor', { command: 'view', path: 'd' }, host);
    expect(out).toContain('f.txt');
  });

  it('ralph needs a subagent host', async () => {
    expect(await runExtraTool('ralph', { objective: 'x' }, host)).toMatch(/needs a subagent host/);
  });

  it('terminal_read honours the since cursor and reports exited shells', async () => {
    const h = makeHost();
    await runExtraTool('terminal_open', {}, h);
    await runExtraTool('terminal_send', { id: 'term-1', input: 'echo first' }, h);
    await new Promise(r => setTimeout(r, 250));
    const before = await runExtraTool('terminal_read', { id: 'term-1' }, h);
    const cursor = before?.length ?? 0;
    await runExtraTool('terminal_send', { id: 'term-1', input: 'exit' }, h);
    await new Promise(r => setTimeout(r, 250));
    const after = await runExtraTool('terminal_read', { id: 'term-1', since: cursor }, h);
    expect(after).toMatch(/status: exited/);
    expect(await runExtraTool('terminal_send', { id: 'term-1', input: 'x' }, h)).toMatch(/has exited/);
  });

  it('plugin_market accepts a URL', async () => {
    const srv = http.createServer((_q, res) => {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ plugins: [{ name: 'remote', version: '2.0.0' }] }));
    });
    await new Promise<void>(r => srv.listen(0, '127.0.0.1', r));
    process.env.TRHA_PLUGIN_MARKET = `http://127.0.0.1:${(srv.address() as AddressInfo).port}/m.json`;
    const out = await runExtraTool('plugin_market', {}, host);
    delete process.env.TRHA_PLUGIN_MARKET;
    srv.close();
    expect(out).toContain('remote');
  });

  it('stagehand tabs and screenshot work on an open page', async () => {
    const srv = http.createServer((_q, res) => {
      res.writeHead(200, { 'content-type': 'text/html' });
      res.end('<html><body><p>tabbed</p></body></html>');
    });
    await new Promise<void>(r => srv.listen(0, '127.0.0.1', r));
    const url = `http://127.0.0.1:${(srv.address() as AddressInfo).port}/`;
    await runExtraTool('stagehand_navigate', { url }, host);
    expect(await runExtraTool('stagehand_tabs', {}, host)).toMatch(/current url/);
    expect(await runExtraTool('stagehand_screenshot', { path: 'sh.png' }, host)).toMatch(/^OK: screenshot/);
    await readFile(path.join(dir, 'sh.png'));
    srv.close();
    await browserCloseAll();
  });

  it('team tools explain a host without agent hooks', async () => {
    const bare = makeHost();
    expect(await runExtraTool('team_task_get', { id: 't1' }, bare)).toMatch(/not available|no team task/);
    expect(await runExtraTool('spawn_teammate', { task: 'x' }, bare)).toMatch(/not available/);
    expect(await runExtraTool('wait_agent', { id: 'x' }, bare)).toMatch(/no agent/);
  });
});
