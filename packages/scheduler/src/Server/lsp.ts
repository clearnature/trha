// Minimal LSP client over stdio (Content-Length framing).
//
// Ported semantics from MiMo-Code's LSP module (lsp/server.ts + tool/lsp.ts):
// several language servers, selected by file extension, with the operations
// the model needs (hover, definition, references, symbols, diagnostics,
// workspace symbols, implementation, call hierarchy).
//
// Config:
//   TRHA_LSP_COMMAND  force one server for every file (legacy; `bin --stdio`)
//   TRHA_LSP_CONFIG   JSON file: { "servers": { "id": { "command": [...],
//                     "extensions": [".foo"], "languageId": "foo" } } }
//   TRHA_LSP_ROOT     workspace root (defaults to TRHA_WORKSPACE / cwd)

import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

interface Waiter { resolve: (v: unknown) => void; reject: (e: Error) => void }

interface LspClient {
  id: string;
  child: ChildProcessWithoutNullStreams;
  nextId: number;
  pending: Map<number, Waiter>;
  diagnostics: Map<string, unknown[]>;
  opened: Set<string>;
  root: string;
  languageId: string;
}

export interface ServerConfig {
  id: string;
  /** Full command line (space-separated) or argv array; normalized to argv. */
  command: string;
  extensions: string[];
  languageId?: string;
}

/** Built-in servers, ordered so more specific extensions win. */
const BUILTINS: ServerConfig[] = [
  { id: 'typescript', command: 'typescript-language-server --stdio', extensions: ['.ts', '.tsx', '.js', '.jsx', '.mjs', '.cjs'] },
  { id: 'rust', command: 'rust-analyzer', extensions: ['.rs'] },
  { id: 'haskell', command: 'haskell-language-server-wrapper --lsp', extensions: ['.hs', '.lhs'] },
  { id: 'python', command: 'pyright-langserver --stdio', extensions: ['.py', '.pyi'] },
  { id: 'go', command: 'gopls', extensions: ['.go'] },
  { id: 'clangd', command: 'clangd', extensions: ['.c', '.cc', '.cpp', '.h', '.hpp'] },
  { id: 'lua', command: 'lua-language-server', extensions: ['.lua'] },
  { id: 'bash', command: 'bash-language-server start', extensions: ['.sh', '.bash'] },
  { id: 'yaml', command: 'yaml-language-server --stdio', extensions: ['.yaml', '.yml'] },
  { id: 'json', command: 'vscode-json-language-server --stdio', extensions: ['.json', '.jsonc'] },
  { id: 'toml', command: 'taplo lsp stdio', extensions: ['.toml'] },
  { id: 'html', command: 'vscode-html-language-server --stdio', extensions: ['.html', '.htm'] },
  { id: 'css', command: 'vscode-css-language-server --stdio', extensions: ['.css', '.scss'] },
];

let configured: ServerConfig[] | undefined;

function splitCommand(cmd: string): string {
  return cmd.trim();
}

/** Read the JSON config once; unknown shapes are ignored. */
async function loadServers(): Promise<ServerConfig[]> {
  if (configured) return configured;
  const forced = process.env.TRHA_LSP_COMMAND;
  if (forced && forced.trim()) {
    configured = [{
      id: 'custom',
      command: forced,
      extensions: ['*'],
    }];
    return configured;
  }
  const servers: ServerConfig[] = [...BUILTINS];
  const file = process.env.TRHA_LSP_CONFIG;
  if (file) {
    try {
      const raw = JSON.parse(await readFile(file, 'utf8')) as {
        servers?: Record<string, { command?: string | string[]; extensions?: string[]; languageId?: string }>;
      };
      for (const [id, cfg] of Object.entries(raw.servers ?? {})) {
        const cmd = Array.isArray(cfg.command) ? cfg.command.join(' ') : cfg.command;
        if (!cmd) continue;
        const exts = (cfg.extensions ?? []).map(e => e.toLowerCase());
        servers.unshift({
          id,
          command: splitCommand(cmd),
          extensions: exts.length > 0 ? exts : ['*'],
          ...(cfg.languageId ? { languageId: cfg.languageId } : {}),
        });
      }
    } catch { /* malformed config: keep the built-ins */ }
  }
  configured = servers;
  return servers;
}

async function serverFor(file: string): Promise<ServerConfig | undefined> {
  const servers = await loadServers();
  const ext = path.extname(file).toLowerCase();
  const exact = servers.find(s => s.extensions.includes(ext));
  return exact ?? servers.find(s => s.extensions.includes('*'));
}

const clients = new Map<string, LspClient>();
const starting = new Map<string, Promise<LspClient>>();

async function startServer(cfg: ServerConfig): Promise<LspClient> {
  const root = process.env.TRHA_LSP_ROOT ?? process.env.TRHA_WORKSPACE ?? process.cwd();
  const existing = clients.get(cfg.id);
  if (existing) return existing;

  const parts = cfg.command.trim().split(/\s+/);
  const bin = parts[0] ?? '';
  if (!bin) throw new Error(`LSP server ${cfg.id}: empty command`);
  const child = spawn(bin, parts.slice(1), { stdio: ['pipe', 'pipe', 'pipe'], cwd: root }) as ChildProcessWithoutNullStreams;
  // A missing language server must fail the tool, not the scheduler: an
  // unhandled 'error' event on ChildProcess terminates the whole process.
  await new Promise<void>((resolve, reject) => {
    child.once('spawn', () => resolve());
    child.once('error', (e: NodeJS.ErrnoException) => {
      reject(new Error(
        e.code === 'ENOENT'
          ? `${cfg.id}: language server "${bin}" not found (install it or set TRHA_LSP_COMMAND)`
          : `${cfg.id}: ${e.message}`,
      ));
    });
  });
  const c: LspClient = {
    id: cfg.id, child, nextId: 1, pending: new Map(), diagnostics: new Map(),
    opened: new Set(), root, languageId: cfg.languageId ?? '',
  };

  let buffer = Buffer.alloc(0);
  child.stdout.on('data', (chunk: Buffer) => {
    buffer = Buffer.concat([buffer, chunk]);
    for (;;) {
      const headerEnd = buffer.indexOf('\r\n\r\n');
      if (headerEnd < 0) return;
      const header = buffer.slice(0, headerEnd).toString('ascii');
      const m = /Content-Length:\s*(\d+)/i.exec(header);
      if (!m) {
        buffer = buffer.slice(headerEnd + 4);
        continue;
      }
      const len = Number(m[1]);
      const start = headerEnd + 4;
      if (buffer.length < start + len) return;
      const body = buffer.slice(start, start + len).toString('utf8');
      buffer = buffer.slice(start + len);
      let msg: { id?: number; method?: string; params?: unknown; result?: unknown; error?: { message: string } };
      try { msg = JSON.parse(body) as typeof msg; } catch { continue; }
      if (msg.id !== undefined) {
        const w = c.pending.get(msg.id);
        if (w) {
          c.pending.delete(msg.id);
          if (msg.error) w.reject(new Error(`LSP: ${msg.error.message}`));
          else w.resolve(msg.result);
        }
      } else if (msg.method === 'textDocument/publishDiagnostics') {
        const p = msg.params as { uri?: string; diagnostics?: unknown[] };
        if (p.uri) c.diagnostics.set(p.uri, p.diagnostics ?? []);
      }
    }
  });
  child.on('exit', () => {
    clients.delete(cfg.id);
    for (const [, w] of c.pending) w.reject(new Error(`[${cfg.id}] language server exited`));
    c.pending.clear();
  });

  const send = (payload: unknown): void => {
    const body = JSON.stringify(payload);
    child.stdin.write(`Content-Length: ${Buffer.byteLength(body, 'utf8')}\r\n\r\n${body}`);
  };
  const request = (method: string, params: unknown): Promise<unknown> => {
    const id = c.nextId++;
    return new Promise((resolve, reject) => {
      c.pending.set(id, { resolve, reject });
      const timer = setTimeout(() => {
        if (c.pending.delete(id)) reject(new Error(`LSP ${method} timed out`));
      }, 20_000);
      timer.unref?.();
      send({ jsonrpc: '2.0', id, method, params });
    });
  };

  await request('initialize', {
    processId: process.pid,
    rootUri: pathToFileURL(root).toString(),
    capabilities: {
      textDocument: {
        hover: { contentFormat: ['markdown', 'plaintext'] },
        definition: {},
        references: {},
        implementation: {},
        documentSymbol: {},
        publishDiagnostics: {},
        callHierarchy: {},
      },
      workspace: { symbol: {} },
    },
    workspaceFolders: [{ uri: pathToFileURL(root).toString(), name: 'workspace' }],
  });
  send({ jsonrpc: '2.0', method: 'initialized', params: {} });
  clients.set(cfg.id, c);
  return c;
}

async function ensureFor(file: string): Promise<LspClient> {
  const cfg = await serverFor(file);
  if (!cfg) {
    throw new Error(`No LSP server available for ${path.extname(file) || file}; set TRHA_LSP_COMMAND or TRHA_LSP_CONFIG`);
  }
  const running = clients.get(cfg.id);
  if (running) return running;
  let pending = starting.get(cfg.id);
  if (!pending) {
    pending = startServer(cfg).finally(() => { starting.delete(cfg.id); });
    starting.set(cfg.id, pending);
  }
  return pending;
}

async function openDocument(c: LspClient, file: string): Promise<string> {
  const uri = pathToFileURL(path.resolve(c.root, file)).toString();
  if (!c.opened.has(uri)) {
    let text = '';
    try { text = await readFile(path.resolve(c.root, file), 'utf8'); } catch { /* diagnostics only */ }
    const body = JSON.stringify({
      jsonrpc: '2.0',
      method: 'textDocument/didOpen',
      params: { textDocument: { uri, languageId: c.languageId || languageFor(file), version: 1, text } },
    });
    c.child.stdin.write(`Content-Length: ${Buffer.byteLength(body, 'utf8')}\r\n\r\n${body}`);
    c.opened.add(uri);
  }
  return uri;
}

function languageFor(file: string): string {
  const ext = path.extname(file).toLowerCase();
  if (ext === '.ts' || ext === '.tsx') return 'typescript';
  if (ext === '.js' || ext === '.mjs' || ext === '.cjs') return 'javascript';
  if (ext === '.hs') return 'haskell';
  if (ext === '.py') return 'python';
  if (ext === '.rs') return 'rust';
  if (ext === '.go') return 'go';
  if (ext === '.c' || ext === '.h') return 'c';
  if (ext === '.cc' || ext === '.cpp' || ext === '.hpp') return 'cpp';
  return 'plaintext';
}

export type LspOperation =
  | 'hover' | 'definition' | 'references' | 'diagnostics' | 'symbols'
  | 'workspaceSymbol' | 'implementation' | 'callHierarchy' | 'incomingCalls' | 'outgoingCalls';

export interface LspArgs {
  file: string;
  operation: LspOperation;
  line?: number;
  character?: number;
  /** Query for workspaceSymbol. */
  query?: string;
}

/** Run one LSP operation and return a compact, model-readable string. */
export async function lspQuery(args: LspArgs): Promise<string> {
  if (!args.file) throw new Error('file is required');
  const c = await ensureFor(args.file);
  const uri = await openDocument(c, args.file);
  const position = { line: Math.max(0, (args.line ?? 1) - 1), character: Math.max(0, (args.character ?? 1) - 1) };

  if (args.operation === 'hover') {
    const r = (await requestOn(c, 'textDocument/hover', { textDocument: { uri }, position })) as {
      contents?: { value?: string } | string;
    } | null;
    if (!r) return '(no hover information)';
    const contents = r.contents;
    return typeof contents === 'string' ? contents : (contents?.value ?? '(empty hover)');
  }
  if (args.operation === 'definition') {
    return formatLocations(await requestOn(c, 'textDocument/definition', { textDocument: { uri }, position }));
  }
  if (args.operation === 'implementation') {
    return formatLocations(await requestOn(c, 'textDocument/implementation', { textDocument: { uri }, position }));
  }
  if (args.operation === 'references') {
    const r = await requestOn(c, 'textDocument/references', {
      textDocument: { uri }, position, context: { includeDeclaration: true },
    });
    return formatLocations(r);
  }
  if (args.operation === 'symbols') {
    const r = (await requestOn(c, 'textDocument/documentSymbol', { textDocument: { uri } })) as Array<{
      name?: string; kind?: number; range?: { start?: { line?: number } };
    }>;
    if (!Array.isArray(r) || r.length === 0) return '(no symbols)';
    return r.map(s => `${s.name ?? '?'} (kind ${s.kind ?? '?'}) @ line ${(s.range?.start?.line ?? 0) + 1}`).join('\n');
  }
  if (args.operation === 'workspaceSymbol') {
    const query = args.query ?? '';
    const r = (await requestOn(c, 'workspace/symbol', { query })) as Array<{
      name?: string; kind?: number; location?: { uri?: string; range?: { start?: { line?: number; character?: number } } };
    }>;
    if (!Array.isArray(r) || r.length === 0) return '(no symbols)';
    return r.slice(0, 100).map(s => {
      const loc = s.location;
      const file = loc?.uri ? decodeURIComponent(loc.uri.replace(/^file:\/\//, '')) : '?';
      return `${s.name ?? '?'} (kind ${s.kind ?? '?'}) @ ${file}:${(loc?.range?.start?.line ?? 0) + 1}`;
    }).join('\n');
  }
  if (args.operation === 'callHierarchy' || args.operation === 'incomingCalls' || args.operation === 'outgoingCalls') {
    const items = (await requestOn(c, 'textDocument/prepareCallHierarchy', {
      textDocument: { uri }, position,
    })) as Array<{ name?: string; kind?: number; uri?: string; range?: unknown; selectionRange?: unknown }>;
    if (!Array.isArray(items) || items.length === 0) return '(no call hierarchy)';
    if (args.operation === 'callHierarchy') {
      return items.map(i => `${i.name ?? '?'} (kind ${i.kind ?? '?'})`).join('\n');
    }
    const method = args.operation === 'incomingCalls' ? 'callHierarchy/incomingCalls' : 'callHierarchy/outgoingCalls';
    const r = (await requestOn(c, method, { item: items[0] })) as Array<{
      from?: { name?: string; uri?: string }; to?: { name?: string; uri?: string };
    }>;
    if (!Array.isArray(r) || r.length === 0) return '(no calls)';
    return r.slice(0, 100).map(x => {
      const other = args.operation === 'incomingCalls' ? x.from : x.to;
      const file = other?.uri ? decodeURIComponent(other.uri.replace(/^file:\/\//, '')) : '?';
      return `${other?.name ?? '?'} @ ${file}`;
    }).join('\n');
  }
  // diagnostics: the server pushes them; give it a moment after didOpen.
  await new Promise(r => setTimeout(r, 300));
  const diags = c.diagnostics.get(uri) ?? [];
  if (diags.length === 0) return '(no diagnostics)';
  return diags.map(d => {
    const o = d as { range?: { start?: { line?: number; character?: number } }; severity?: number; message?: string };
    const line = (o.range?.start?.line ?? 0) + 1;
    return `${line}:${(o.range?.start?.character ?? 0) + 1} severity=${o.severity ?? 0} ${o.message ?? ''}`;
  }).join('\n');
}

function requestOn(c: LspClient, method: string, params: unknown): Promise<unknown> {
  const id = c.nextId++;
  const body = JSON.stringify({ jsonrpc: '2.0', id, method, params });
  return new Promise((resolve, reject) => {
    c.pending.set(id, { resolve, reject });
    const timer = setTimeout(() => {
      if (c.pending.delete(id)) reject(new Error(`LSP ${method} timed out`));
    }, 20_000);
    timer.unref?.();
    c.child.stdin.write(`Content-Length: ${Buffer.byteLength(body, 'utf8')}\r\n\r\n${body}`);
  });
}

function formatLocations(r: unknown): string {
  const arr = Array.isArray(r) ? r : r ? [r] : [];
  if (arr.length === 0) return '(no locations)';
  return arr.map(item => {
    const loc = item as { uri?: string; range?: { start?: { line?: number; character?: number } } };
    if (!loc.uri) return JSON.stringify(item);
    const file = loc.uri.startsWith('file://') ? decodeURIComponent(loc.uri.slice('file://'.length)) : loc.uri;
    return `${file}:${(loc.range?.start?.line ?? 0) + 1}:${(loc.range?.start?.character ?? 0) + 1}`;
  }).join('\n');
}

export function shutdownLsp(): void {
  for (const [, c] of clients) c.child.kill('SIGTERM');
  clients.clear();
  starting.clear();
  configured = undefined;
}

/** Language-server state for the sidebar. */
export function lspStatus(): {
  running: boolean;
  diagnostics: number;
  servers: Array<{ id: string; running: boolean; diagnostics: number }>;
} {
  const servers = Array.from(clients.values()).map(c => ({
    id: c.id, running: true, diagnostics: c.diagnostics.size,
  }));
  return {
    running: servers.length > 0,
    diagnostics: servers.reduce((n, s) => n + s.diagnostics, 0),
    servers,
  };
}
