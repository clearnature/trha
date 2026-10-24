// MCP and LSP clients: exercised against real child processes that speak the
// protocols (fake servers), so the framing — not just the branching — is tested.

import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { runStandardTool, type StandardToolHost } from '../src/Server/standardTools.js';
import { shutdownLsp } from '../src/Server/lsp.js';
import { shutdownMcp } from '../src/Server/mcp.js';

const MCP_SERVER = `#!/usr/bin/env node
let buf = '';
const send = (o) => process.stdout.write(JSON.stringify(o) + '\\n');
process.stdin.on('data', (c) => {
  buf += c.toString('utf8');
  let i;
  while ((i = buf.indexOf('\\n')) >= 0) {
    const line = buf.slice(0, i).trim(); buf = buf.slice(i + 1);
    if (!line) continue;
    let msg; try { msg = JSON.parse(line); } catch { continue; }
    if (msg.id === undefined) continue;              // notification
    if (msg.method === 'initialize') {
      send({ jsonrpc: '2.0', id: msg.id, result: { protocolVersion: '2024-11-05', capabilities: { resources: {} } } });
    } else if (msg.method === 'resources/list') {
      send({ jsonrpc: '2.0', id: msg.id, result: { resources: [
        { uri: 'file:///notes.txt', name: 'notes', mimeType: 'text/plain' },
      ] } });
    } else if (msg.method === 'resources/templates/list') {
      send({ jsonrpc: '2.0', id: msg.id, result: { resourceTemplates: [
        { uriTemplate: 'file:///{path}', name: 'files' },
      ] } });
    } else if (msg.method === 'resources/read') {
      send({ jsonrpc: '2.0', id: msg.id, result: { contents: [
        { uri: msg.params.uri, mimeType: 'text/plain', text: 'hello from mcp' },
      ] } });
    } else {
      send({ jsonrpc: '2.0', id: msg.id, error: { code: -32601, message: 'unknown method' } });
    }
  }
});
`;

const LSP_SERVER = `#!/usr/bin/env node
let buf = Buffer.alloc(0);
function send(o) {
  const body = JSON.stringify(o);
  process.stdout.write('Content-Length: ' + Buffer.byteLength(body, 'utf8') + '\\r\\n\\r\\n' + body);
}
process.stdin.on('data', (c) => {
  buf = Buffer.concat([buf, c]);
  for (;;) {
    const he = buf.indexOf('\\r\\n\\r\\n');
    if (he < 0) return;
    const m = /Content-Length:\\s*(\\d+)/i.exec(buf.slice(0, he).toString('ascii'));
    if (!m) { buf = buf.slice(he + 4); continue; }
    const len = Number(m[1]);
    if (buf.length < he + 4 + len) return;
    const body = buf.slice(he + 4, he + 4 + len).toString('utf8');
    buf = buf.slice(he + 4 + len);
    let msg; try { msg = JSON.parse(body); } catch { continue; }
    if (msg.id === undefined) {
      if (msg.method === 'textDocument/didOpen') {
        send({ jsonrpc: '2.0', method: 'textDocument/publishDiagnostics', params: {
          uri: msg.params.textDocument.uri,
          diagnostics: [{ range: { start: { line: 2, character: 0 } }, severity: 1, message: 'fake warning' }],
        } });
      }
      continue;
    }
    if (msg.method === 'initialize') {
      send({ jsonrpc: '2.0', id: msg.id, result: { capabilities: { hoverProvider: true } } });
    } else if (msg.method === 'textDocument/hover') {
      send({ jsonrpc: '2.0', id: msg.id, result: { contents: { kind: 'markdown', value: '**hover text**' } } });
    } else if (msg.method === 'textDocument/definition') {
      send({ jsonrpc: '2.0', id: msg.id, result: [
        { uri: 'file:///tmp/def.ts', range: { start: { line: 4, character: 2 } } },
      ] });
    } else if (msg.method === 'textDocument/references') {
      send({ jsonrpc: '2.0', id: msg.id, result: [
        { uri: 'file:///tmp/a.ts', range: { start: { line: 0, character: 0 } } },
        { uri: 'file:///tmp/b.ts', range: { start: { line: 8, character: 4 } } },
      ] });
    } else if (msg.method === 'textDocument/documentSymbol') {
      send({ jsonrpc: '2.0', id: msg.id, result: [
        { name: 'main', kind: 12, range: { start: { line: 6, character: 0 } } },
      ] });
    } else {
      send({ jsonrpc: '2.0', id: msg.id, error: { message: 'unknown method' } });
    }
  }
});
`;

function host(workspace: string): StandardToolHost {
  return { workspace, state: {}, jobs: new Map(), sessionId: 's' };
}

describe('MCP client', () => {
  let dir: string;
  beforeEach(async () => {
    dir = await mkdtemp(path.join(tmpdir(), 'trha-mcp-'));
    const script = path.join(dir, 'mcp-server.mjs');
    await writeFile(script, MCP_SERVER, { mode: 0o755 });
    const cfg = path.join(dir, 'mcp.json');
    await writeFile(cfg, JSON.stringify({ servers: { fake: { command: process.execPath, args: [script] } } }));
    process.env.TRHA_MCP_CONFIG = cfg;
  });
  afterEach(async () => {
    shutdownMcp();
    delete process.env.TRHA_MCP_CONFIG;
    await rm(dir, { recursive: true, force: true });
  });

  it('lists resources, templates and reads one by uri', async () => {
    const h = host(dir);
    const listed = await runStandardTool('list_mcp_resources', {}, h);
    expect(listed).toContain('file:///notes.txt');
    expect(listed).toContain('notes');

    const templates = await runStandardTool('list_mcp_resource_templates', {}, h);
    expect(templates).toContain('file:///{path}');

    const read = await runStandardTool('read_mcp_resource', { uri: 'file:///notes.txt' }, h);
    expect(read).toContain('hello from mcp');
  });

  it('reports a clear error when nothing is configured', async () => {
    delete process.env.TRHA_MCP_CONFIG;
    const out = await runStandardTool('list_mcp_resources', {}, host(dir));
    expect(out).toMatch(/^ERROR: no MCP servers configured/);
  });
});

describe('LSP client', () => {
  let dir: string;
  beforeEach(async () => {
    dir = await mkdtemp(path.join(tmpdir(), 'trha-lsp-'));
    const script = path.join(dir, 'lsp-server.mjs');
    await writeFile(script, LSP_SERVER, { mode: 0o755 });
    await writeFile(path.join(dir, 'a.ts'), 'const x = 1;\nconst y = 2;\nconst z = 3;\n');
    process.env.TRHA_LSP_COMMAND = `${process.execPath} ${script}`;
    process.env.TRHA_LSP_ROOT = dir;
  });
  afterEach(async () => {
    shutdownLsp();
    delete process.env.TRHA_LSP_COMMAND;
    delete process.env.TRHA_LSP_ROOT;
    await rm(dir, { recursive: true, force: true });
  });

  it('answers hover, definition, references and symbols', async () => {
    const h = host(dir);
    const hover = await runStandardTool('lsp', { file: 'a.ts', operation: 'hover', line: 2, character: 7 }, h);
    expect(hover).toContain('hover text');

    const def = await runStandardTool('lsp', { file: 'a.ts', operation: 'definition', line: 2 }, h);
    expect(def).toContain('/tmp/def.ts:5:3');

    const refs = await runStandardTool('lsp', { file: 'a.ts', operation: 'references', line: 2 }, h);
    expect(refs).toContain('/tmp/a.ts:1:1');
    expect(refs).toContain('/tmp/b.ts:9:5');

    const symbols = await runStandardTool('lsp', { file: 'a.ts', operation: 'symbols' }, h);
    expect(symbols).toContain('main');
    expect(symbols).toContain('line 7');
  });

  it('returns the diagnostics the server published on open', async () => {
    const out = await runStandardTool('lsp', { file: 'a.ts', operation: 'diagnostics' }, host(dir));
    expect(out).toContain('fake warning');
    expect(out).toContain('3:1');
  });

  it('rejects an unknown operation instead of guessing', async () => {
    const out = await runStandardTool('lsp', { file: 'a.ts', operation: 'rename' }, host(dir));
    expect(out).toMatch(/operation must be/);
  });
});
