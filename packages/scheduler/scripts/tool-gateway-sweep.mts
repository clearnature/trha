// Real gateway sweep: every catalogued tool goes through the same HTTP surface
// the shell uses (`/api/agent/step` → runStep → executeTool), with a scripted
// model so each tool gets exactly one call and the result is observable.
//
// The model is scripted on purpose: this is a wiring/behaviour sweep, not a
// model evaluation. Fixtures are real (HTTP page, MCP/LSP child processes, git
// repo, package.json), so "works" means the tool actually did something.

import express from 'express';
import http from 'node:http';
import type { AddressInfo } from 'node:net';
import { mkdtemp, mkdir, writeFile, readdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { createServer } from '../src/Server/index.js';
import { toolCatalog } from '../src/Server/toolCatalog.js';

const auth = { 'Content-Type': 'application/json', Authorization: 'Bearer dev-token' } as Record<string, string>;

const dir = await mkdtemp(path.join(tmpdir(), 'trha-sweep-'));
const workspace = path.join(dir, 'ws');
await mkdir(workspace, { recursive: true });
process.env.TRHA_WORKSPACE = workspace;
process.env.TRHA_SCHEDULE_TICK_MS = '0';
process.env.TRHA_MAX_SUBAGENT_DEPTH = '2';

// ── fixtures ────────────────────────────────────────────────────────────
const page = http.createServer((_q, res) => {
  res.writeHead(200, { 'content-type': 'text/html' });
  res.end('<html><head><title>Sweep</title></head><body><h1>hello page</h1><button id="b">Go</button></body></html>');
});
await new Promise<void>(r => page.listen(0, '127.0.0.1', r));
const pageUrl = `http://127.0.0.1:${(page.address() as AddressInfo).port}/`;

const searx = http.createServer((_q, res) => {
  res.writeHead(200, { 'content-type': 'application/json' });
  res.end(JSON.stringify({ results: [{ title: 'Searched', url: 'https://example.com', content: 'found it' }] }));
});
await new Promise<void>(r => searx.listen(0, '127.0.0.1', r));
process.env.TRHA_SEARX_URL = `http://127.0.0.1:${(searx.address() as AddressInfo).port}`;

// fake MCP server
const mcpScript = path.join(dir, 'mcp.mjs');
await writeFile(mcpScript, `#!/usr/bin/env node
let buf='';const send=o=>process.stdout.write(JSON.stringify(o)+'\\n');
process.stdin.on('data',c=>{buf+=c;let i;while((i=buf.indexOf('\\n'))>=0){const l=buf.slice(0,i).trim();buf=buf.slice(i+1);if(!l)continue;const m=JSON.parse(l);if(m.id===undefined)continue;
if(m.method==='initialize')send({jsonrpc:'2.0',id:m.id,result:{protocolVersion:'2024-11-05',capabilities:{}}});
else if(m.method==='resources/list')send({jsonrpc:'2.0',id:m.id,result:{resources:[{uri:'file:///n.txt',name:'n'}]}});
else if(m.method==='resources/templates/list')send({jsonrpc:'2.0',id:m.id,result:{resourceTemplates:[{uriTemplate:'file:///{p}',name:'t'}]}});
else if(m.method==='resources/read')send({jsonrpc:'2.0',id:m.id,result:{contents:[{uri:m.params.uri,text:'mcp text'}]}});
}});
`, { mode: 0o755 });
const mcpCfg = path.join(dir, 'mcp.json');
await writeFile(mcpCfg, JSON.stringify({ servers: { fake: { command: process.execPath, args: [mcpScript] } } }));
process.env.TRHA_MCP_CONFIG = mcpCfg;

// fake LSP server
const lspScript = path.join(dir, 'lsp.mjs');
await writeFile(lspScript, `#!/usr/bin/env node
let buf=Buffer.alloc(0);const send=o=>{const b=JSON.stringify(o);process.stdout.write('Content-Length: '+Buffer.byteLength(b)+'\\r\\n\\r\\n'+b)};
process.stdin.on('data',c=>{buf=Buffer.concat([buf,c]);for(;;){const he=buf.indexOf('\\r\\n\\r\\n');if(he<0)return;const m=/Content-Length:\\s*(\\d+)/i.exec(buf.slice(0,he).toString());if(!m){buf=buf.slice(he+4);continue}const n=Number(m[1]);if(buf.length<he+4+n)return;const body=buf.slice(he+4,he+4+n).toString();buf=buf.slice(he+4+n);const msg=JSON.parse(body);
if(msg.id===undefined)continue;
if(msg.method==='initialize')send({jsonrpc:'2.0',id:msg.id,result:{capabilities:{}}});
else if(msg.method==='textDocument/hover')send({jsonrpc:'2.0',id:msg.id,result:{contents:{value:'hover!'}}});
else if(msg.method==='textDocument/definition')send({jsonrpc:'2.0',id:msg.id,result:[]});
else if(msg.method==='textDocument/references')send({jsonrpc:'2.0',id:msg.id,result:[]});
else if(msg.method==='textDocument/documentSymbol')send({jsonrpc:'2.0',id:msg.id,result:[{name:'f',kind:12,range:{start:{line:0}}}]});
}});
`, { mode: 0o755 });
process.env.TRHA_LSP_COMMAND = `${process.execPath} ${lspScript}`;
process.env.TRHA_LSP_ROOT = workspace;
await writeFile(path.join(workspace, 'a.ts'), 'const x = 1;\n');
await writeFile(path.join(workspace, 'notes.txt'), 'alpha\nbeta\n');
await writeFile(path.join(workspace, 'img.png'), Buffer.from([0x89, 0x50, 0x4e, 0x47, 0, 0, 0, 0]));
await writeFile(path.join(workspace, 'package.json'), JSON.stringify({ name: 'sweep', version: '1.0.0' }));
await mkdir(path.join(workspace, '.trha', 'skills'), { recursive: true });
await writeFile(path.join(workspace, '.trha', 'skills', 'demo.md'), '# demo skill');

const git = (cmd: string): Promise<void> => new Promise((resolve, reject) => {
  import('node:child_process').then(({ execFile }) => {
    execFile('bash', ['-lc', `cd ${workspace} && ${cmd}`], err => (err ? reject(err) : resolve()));
  });
});
await git('git init -q && git config user.email t@e.x && git config user.name t && git add -A && git commit -qm init');

// ── scripted kernel: one tool call per turn ─────────────────────────────
const calls = new Map<string, Array<{ name: string; args: Record<string, unknown> }>>();
const kernel = express();
kernel.use(express.json());
kernel.post('/session/start', (_q, res) => res.json({}));
kernel.post('/v1/chat/completions', (req, res) => {
  const msgs = req.body.messages as Array<{ role: string; content: string; tool_calls?: unknown[] }>;
  const lastUser = [...msgs].reverse().find(m => m.role === 'user')?.content ?? '';
  const toolResults = msgs.filter(m => m.role === 'tool');
  const script = calls.get(lastUser);
  // One call per round: the round index is how many tool results already exist.
  const next = script?.[toolResults.length];
  if (next) {
    return res.json({
      choices: [{
        message: {
          role: 'assistant', content: '',
          tool_calls: [{ id: `c-${next.name}-${toolResults.length}`, type: 'function', function: { name: next.name, arguments: JSON.stringify(next.args) } }],
        },
        finish_reason: 'tool_calls',
      }],
    });
  }
  const out = toolResults[toolResults.length - 1]?.content ?? '(no tool result)';
  res.json({ choices: [{ message: { role: 'assistant', content: out, finish_reason: 'stop' } }] });
});
const kernelServer = await new Promise<http.Server>(resolve => {
  const s = kernel.listen(0, '127.0.0.1', () => resolve(s));
});
const stateDir = path.join(dir, 'state');
const { app, stop } = createServer({
  port: 0, token: 'dev-token',
  haskellHost: '127.0.0.1', haskellPort: (kernelServer.address() as AddressInfo).port,
  stateDir,
});
const scheduler = await new Promise<http.Server>(resolve => {
  const s = app.listen(0, '127.0.0.1', () => resolve(s));
});
const base = `http://127.0.0.1:${(scheduler.address() as AddressInfo).port}`;

// ── per-tool arguments ──────────────────────────────────────────────────
const args: Record<string, Record<string, unknown>> = {
  bash: { command: 'echo bash-ok' },
  read: { path: 'notes.txt', offset: 1, limit: 2 },
  write: { path: 'w.txt', content: 'written' },
  edit: { path: 'notes.txt', old_string: 'beta', new_string: 'BETA' },
  glob: { pattern: '*.txt', path: '.' },
  grep: { pattern: 'alpha', path: '.' },
  append_file: { path: 'w.txt', content: '\nmore' },
  subagent: { task: 'say hi', name: 'kid' },
  list_agents: {},
  send_message: { to: 'x', text: 'hi' },
  interrupt_agent: { id: 'x' },
  team_task_create: { subject: 'sweep task' },
  team_task_list: {},
  team_task_update: { id: 't1', status: 'completed' },
  team_task_get: { id: 't1' },
  workflow: { steps: [{ name: 'a', task: 'one' }] },
  list_mcp_resources: {},
  list_mcp_resource_templates: {},
  read_mcp_resource: { uri: 'file:///n.txt' },
  lsp: { file: 'a.ts', operation: 'hover', line: 1, character: 1 },
  browser_navigate: { url: pageUrl },
  browser_extract: { selector: 'h1' },
  browser_screenshot: { path: 'shot.png' },
  browser_close: {},
  ask_user_question: { question: 'pick one', options: ['a', 'b'] },
  exit_plan_mode: { plan: 'do the sweep' },
  present: { title: 'Sweep', body: 'done' },
  run_code: { language: 'python', code: 'print("code-ok")' },
  read_image: { path: 'img.png' },
  todo_write: { todos: [{ text: 'first', status: 'in_progress' }] },
  create_goal: { objective: 'sweep' },
  get_goal: {},
  update_goal: { status: 'complete' },
  schedule_create: { prompt: 'later', at: new Date(Date.now() + 3600_000).toISOString() },
  schedule_list: {},
  schedule_update: { id: 'sch-1', prompt: 'changed' },
  schedule_delete: { id: 'sch-1' },
  job_list: {},
  job_output: { id: 'job-1' },
  job_kill: { id: 'job-1' },
  skill: { name: 'demo' },
  web_fetch: { url: pageUrl },
  working_directory: { path: 'sub' },
  str_replace_editor: { command: 'view', path: 'notes.txt' },
  unified_edit: { command: 'view', path: 'notes.txt' },
  terminal_open: {},
  terminal_send: { id: 'term-1', input: 'echo term-ok' },
  terminal_read: { id: 'term-1' },
  terminal_signal: { id: 'term-1' },
  terminal_close: { id: 'term-1' },
  terminal_list: {},
  wait_agent: { id: 'x', timeout_ms: 200 },
  spawn_teammate: { task: 'say hi', name: 'mate' },
  session_search: { query: 'sweep' },
  session_trace: {},
  session_event_read: {},
  session_event_search: { query: 'sweep' },
  session_event_trace: {},
  create_worktree: { path: 'wt', branch: 'sweep-branch' },
  load_workspace_dependencies: {},
  pwsh: { command: 'echo hi' },
  web_search: { query: 'sweep' },
  list_subagent_models: {},
  plugin_manager: {},
  cordis_inspect_list: {},
  cordis_inspect_query: { name: 'nope' },
  plugin_market: {},
  stagehand_navigate: { url: pageUrl },
  stagehand_extract: { selector: 'h1' },
  stagehand_screenshot: { path: 'sh2.png' },
  stagehand_tabs: {},
  stagehand_observe: {},
  stagehand_act: { action: 'click', selector: '#b' },
  ralph: { objective: 'finish', rounds: 1 },
};
await mkdir(path.join(workspace, 'sub'), { recursive: true });

// ── sweep ───────────────────────────────────────────────────────────────
const rows: Array<{ tool: string; verdict: string; detail: string }> = [];

/** Stateful groups need their setup in the same session; order matters. */
const sequences: string[][] = [
  ['create_goal', 'get_goal', 'update_goal'],
  ['todo_write', 'team_task_create', 'team_task_list', 'team_task_update', 'team_task_get'],
  ['schedule_create', 'schedule_list', 'schedule_update', 'schedule_delete'],
  ['terminal_open', 'terminal_send', 'terminal_read', 'terminal_list', 'terminal_close'],
  ['subagent', 'list_agents'],
  ['bash', 'job_list', 'job_output', 'job_kill'],
  ['session_event_read', 'session_event_search', 'session_event_trace'],
];
const sequenced = new Set(sequences.flat());

async function runOne(name: string, trigger: string, script: Array<{ name: string; args: Record<string, unknown> }>): Promise<void> {
  calls.set(trigger, script);
  const started = Date.now();
  let detail = '';
  let verdict = 'ok';
  try {
    const startRes = await fetch(`${base}/api/session/start`, {
      method: 'POST', headers: auth, body: JSON.stringify({ mode: 'standard' }),
    });
    const { sessionId } = (await startRes.json()) as { sessionId: string };
    const res = await fetch(`${base}/api/agent/step`, {
      method: 'POST', headers: auth, body: JSON.stringify({ sessionId, message: trigger }),
    });
    const body = (await res.json()) as { reply?: string; error?: string };
    detail = String(body.reply ?? body.error ?? '').replace(/\s+/g, ' ').slice(0, 110);
    if (res.status !== 200) verdict = `http ${res.status}`;
    else if (/unknown tool|not available in this host/i.test(detail)) verdict = 'unwired';
    else if (/^ERROR:/i.test(detail)) {
      // A refusal with a reason ("no such id", "not configured", "missing
      // binary") is the tool working as documented; anything else is a defect.
      verdict = /^ERROR: (no |not configured|pwsh is not installed|plugin_market needs)/i.test(detail)
        ? 'refused' : 'error';
    }
    else if (detail.length === 0) verdict = 'empty';
  } catch (e) {
    verdict = 'threw';
    detail = String(e).slice(0, 110);
  }
  rows.push({ tool: name, verdict, detail: `${detail} (${Date.now() - started}ms)` });
}

// stateful groups first (one session each, scripted in order)
for (const group of sequences) {
  const script = group.map(n => ({
    name: n,
    // the job sequence's bash call must start a *background* job
    args: group[0] === 'bash' && n === 'bash'
      ? { command: 'sleep 0.2; echo job-done', background: true }
      : (args[n] ?? {}),
  }));
  await runOne(`${group.join(' → ')}`, `seq:${group[0]}`, script);
}

// the rest, one session per tool
for (const t of toolCatalog) {
  if (sequenced.has(t.name)) continue;
  await runOne(t.name, `run:${t.name}`, [{ name: t.name, args: args[t.name] ?? {} }]);
}

// job tools need a real background job first
calls.set('job-setup', [{ name: 'bash', args: { command: 'sleep 0.2; echo job-done', background: true } }]);
{
  const started = Date.now();
  const startRes = await fetch(`${base}/api/session/start`, {
    method: 'POST', headers: auth, body: JSON.stringify({ mode: 'standard' }),
  });
  const { sessionId } = (await startRes.json()) as { sessionId: string };
  const step = await fetch(`${base}/api/agent/step`, {
    method: 'POST', headers: auth, body: JSON.stringify({ sessionId, message: 'job-setup' }),
  });
  const body = (await step.json()) as { reply?: string };
  rows.push({ tool: 'bash(background) → job_output', verdict: /started job-/.test(body.reply ?? '') ? 'ok' : 'error', detail: String(body.reply ?? '').slice(0, 110) + ` (${Date.now() - started}ms)` });
}

const tally = rows.reduce<Record<string, number>>((acc, r) => {
  acc[r.verdict] = (acc[r.verdict] ?? 0) + 1;
  return acc;
}, {});

const lines = [
  `# Tool gateway sweep (${new Date().toISOString().slice(0, 19)}Z)`,
  '',
  `Tools: ${toolCatalog.length} · rows: ${rows.length} · verdicts: ${JSON.stringify(tally)}`,
  '',
  '| tool / sequence | verdict | detail |',
  '|---|---|---|',
  ...rows.map(r => `| \`${r.tool}\` | ${r.verdict} | ${r.detail.replace(/\|/g, '\\|')} |`),
];
console.log(lines.join('\n'));

// leftovers, for eyeballing
await readdir(workspace).catch(() => []);
stop();
kernelServer.close();
scheduler.close();
// Child processes (browser, MCP/LSP servers, terminals) keep the loop alive.
const { browserCloseAll } = await import('../src/Server/browser.js');
const { shutdownMcp } = await import('../src/Server/mcp.js');
const { shutdownLsp } = await import('../src/Server/lsp.js');
await browserCloseAll(); shutdownMcp(); shutdownLsp();
setTimeout(() => process.exit(0), 100);
