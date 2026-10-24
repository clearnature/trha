// Minimal LSP client over stdio (Content-Length framing).
//
// Ported semantics from deepseek-harness's `lsp` tool: a single operation per
// call against one configured language server. Supported: hover, definition,
// references, diagnostics, document symbols.
//
// Config: TRHA_LSP_COMMAND (default `typescript-language-server --stdio`) and
// TRHA_LSP_ROOT (defaults to the workspace).

import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

interface Waiter { resolve: (v: unknown) => void; reject: (e: Error) => void }

interface LspClient {
  child: ChildProcessWithoutNullStreams;
  nextId: number;
  pending: Map<number, Waiter>;
  diagnostics: Map<string, unknown[]>;
  opened: Set<string>;
  root: string;
}

let client: LspClient | undefined;
let starting: Promise<LspClient> | undefined;

function splitCommand(cmd: string): { bin: string; args: string[] } {
  const parts = cmd.trim().split(/\s+/);
  return { bin: parts[0] ?? '', args: parts.slice(1) };
}

async function start(): Promise<LspClient> {
  const root = process.env.TRHA_LSP_ROOT ?? process.env.TRHA_WORKSPACE ?? process.cwd();
  const { bin, args } = splitCommand(process.env.TRHA_LSP_COMMAND ?? 'typescript-language-server --stdio');
  if (!bin) throw new Error('TRHA_LSP_COMMAND is empty');

  const child = spawn(bin, args, { stdio: ['pipe', 'pipe', 'pipe'], cwd: root }) as ChildProcessWithoutNullStreams;
  const c: LspClient = { child, nextId: 1, pending: new Map(), diagnostics: new Map(), opened: new Set(), root };

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
    client = undefined;
    for (const [, w] of c.pending) w.reject(new Error('language server exited'));
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

  c.pending.set(-1, { resolve: () => {}, reject: () => {} });
  c.pending.delete(-1);
  await request('initialize', {
    processId: process.pid,
    rootUri: pathToFileURL(c.root).toString(),
    capabilities: {
      textDocument: {
        hover: { contentFormat: ['markdown', 'plaintext'] },
        definition: {},
        references: {},
        documentSymbol: {},
        publishDiagnostics: {},
      },
    },
    workspaceFolders: [{ uri: pathToFileURL(c.root).toString(), name: 'workspace' }],
  });
  send({ jsonrpc: '2.0', method: 'initialized', params: {} });
  client = c;
  return c;
}

async function ensure(): Promise<LspClient> {
  if (client) return client;
  starting ??= start().finally(() => { starting = undefined; });
  return starting;
}

async function openDocument(c: LspClient, file: string): Promise<string> {
  const uri = pathToFileURL(path.resolve(c.root, file)).toString();
  if (!c.opened.has(uri)) {
    let text = '';
    try { text = await readFile(path.resolve(c.root, file), 'utf8'); } catch { /* diagnostics only */ }
    c.child.stdin.write('');
    const body = JSON.stringify({
      jsonrpc: '2.0',
      method: 'textDocument/didOpen',
      params: { textDocument: { uri, languageId: languageFor(file), version: 1, text } },
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
  return 'plaintext';
}

export interface LspArgs {
  file: string;
  operation: 'hover' | 'definition' | 'references' | 'diagnostics' | 'symbols';
  line?: number;
  character?: number;
}

/** Run one LSP operation and return a compact, model-readable string. */
export async function lspQuery(args: LspArgs): Promise<string> {
  if (!args.file) throw new Error('file is required');
  const c = await ensure();
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
    const r = await requestOn(c, 'textDocument/definition', { textDocument: { uri }, position });
    return formatLocations(r);
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
  // diagnostics: the server pushes them; ask for a pull if supported, else use
  // whatever arrived after didOpen.
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
  client?.child.kill('SIGTERM');
  client = undefined;
}
