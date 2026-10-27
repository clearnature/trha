// Minimal MCP client (stdio, newline-delimited JSON-RPC 2.0).
//
// Ported semantics from deepseek-harness's MCP resource tools: discover servers
// from a config file, `initialize`, then `resources/list` / `resources/read` /
// `resources/templates/list`. Deliberately small: no transport negotiation, no
// sampling, no prompts — just what the three resource tools need.
//
// Config: TRHA_MCP_CONFIG points at JSON like
//   { "servers": { "fs": { "command": "mcp-server-fs", "args": ["/tmp"] } } }
// Servers are spawned lazily on first use and kept for the process lifetime.

import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import { readFile } from 'node:fs/promises';

export interface McpServerConfig {
  command: string;
  args?: string[];
  env?: Record<string, string>;
}

export interface McpResource {
  uri: string;
  name?: string;
  mimeType?: string;
  description?: string;
}

interface RpcResponse {
  jsonrpc: '2.0';
  id: number | string;
  result?: unknown;
  error?: { code: number; message: string };
}

interface Client {
  child: ChildProcessWithoutNullStreams;
  nextId: number;
  pending: Map<number, { resolve: (v: unknown) => void; reject: (e: Error) => void }>;
  ready: Promise<void>;
}

const clients = new Map<string, Client>();

async function loadConfig(): Promise<Record<string, McpServerConfig>> {
  const file = process.env.TRHA_MCP_CONFIG;
  if (!file) return {};
  try {
    const raw = JSON.parse(await readFile(file, 'utf8')) as { servers?: Record<string, McpServerConfig> };
    // 缺 command 的条目在 loadConfig 就丢弃：否则它会带着 undefined 一路走到
    // spawn 才炸出不可读的 TypeError，违反本模块「失败必须是可读 ERROR」的契约。
    const out: Record<string, McpServerConfig> = {};
    for (const [id, cfg] of Object.entries(raw.servers ?? {})) {
      if (typeof cfg?.command !== 'string' || !cfg.command.trim()) continue;
      out[id] = cfg;
    }
    return out;
  } catch {
    return {};
  }
}

/** Start (or reuse) one server and complete the MCP handshake. */
async function connect(name: string, cfg: McpServerConfig): Promise<Client> {
  const existing = clients.get(name);
  if (existing) {
    await existing.ready;
    return existing;
  }

  const child = spawn(cfg.command, cfg.args ?? [], {
    stdio: ['pipe', 'pipe', 'pipe'],
    env: { ...process.env, ...cfg.env },
  }) as ChildProcessWithoutNullStreams;
  // An MCP server that cannot be spawned must fail its tool, not the whole
  // scheduler (an unhandled ChildProcess 'error' event exits Node).
  await new Promise<void>((resolve, reject) => {
    child.once('spawn', () => resolve());
    child.once('error', reject);
  });

  const client: Client = { child, nextId: 1, pending: new Map(), ready: Promise.resolve() };
  let buffer = '';
  child.stdout.on('data', (chunk: Buffer) => {
    buffer += chunk.toString('utf8');
    let nl = buffer.indexOf('\n');
    while (nl >= 0) {
      const line = buffer.slice(0, nl).trim();
      buffer = buffer.slice(nl + 1);
      if (line) {
        try {
          const msg = JSON.parse(line) as RpcResponse;
          const waiter = typeof msg.id === 'number' ? client.pending.get(msg.id) : undefined;
          if (waiter) {
            client.pending.delete(msg.id as number);
            if (msg.error) waiter.reject(new Error(`MCP ${name}: ${msg.error.message}`));
            else waiter.resolve(msg.result);
          }
        } catch {
          // a server may log to stdout; ignore non-JSON lines
        }
      }
      nl = buffer.indexOf('\n');
    }
  });
  child.on('exit', () => {
    clients.delete(name);
    for (const [, w] of client.pending) w.reject(new Error(`MCP ${name} exited`));
    client.pending.clear();
  });

  const request = (method: string, params: unknown): Promise<unknown> => {
    const id = client.nextId++;
    const payload = JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n';
    return new Promise((resolve, reject) => {
      client.pending.set(id, { resolve, reject });
      const timer = setTimeout(() => {
        if (client.pending.delete(id)) reject(new Error(`MCP ${name}: ${method} timed out`));
      }, 15_000);
      timer.unref?.();
      child.stdin.write(payload);
    });
  };

  client.ready = (async () => {
    await request('initialize', {
      protocolVersion: '2024-11-05',
      capabilities: {},
      clientInfo: { name: 'trha', version: '0.1.0' },
    });
    // Notification: no id, no reply.
    child.stdin.write(JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' }) + '\n');
  })();
  await client.ready;
  clients.set(name, client);
  return client;
}

async function anyClient(): Promise<{ name: string; client: Client }> {
  const servers = await loadConfig();
  const first = Object.entries(servers)[0];
  if (!first) throw new Error('no MCP servers configured (TRHA_MCP_CONFIG)');
  const [name, cfg] = first;
  return { name, client: await connect(name, cfg) };
}

export async function listMcpResources(server?: string): Promise<McpResource[]> {
  const servers = await loadConfig();
  const names = server ? [server] : Object.keys(servers);
  if (names.length === 0) throw new Error('no MCP servers configured (TRHA_MCP_CONFIG)');
  const out: McpResource[] = [];
  for (const name of names) {
    const cfg = servers[name];
    if (!cfg) throw new Error(`unknown MCP server "${name}"`);
    const client = await connect(name, cfg);
    const result = (await requestOn(client, 'resources/list', {})) as { resources?: McpResource[] };
    for (const r of result.resources ?? []) out.push(r);
  }
  return out;
}

export async function listMcpResourceTemplates(server?: string): Promise<Array<{ uriTemplate: string; name?: string }>> {
  const servers = await loadConfig();
  const names = server ? [server] : Object.keys(servers);
  if (names.length === 0) throw new Error('no MCP servers configured (TRHA_MCP_CONFIG)');
  const out: Array<{ uriTemplate: string; name?: string }> = [];
  for (const name of names) {
    const cfg = servers[name];
    if (!cfg) throw new Error(`unknown MCP server "${name}"`);
    const client = await connect(name, cfg);
    const result = (await requestOn(client, 'resources/templates/list', {})) as {
      resourceTemplates?: Array<{ uriTemplate: string; name?: string }>;
    };
    out.push(...(result.resourceTemplates ?? []));
  }
  return out;
}

export async function readMcpResource(uri: string, server?: string): Promise<string> {
  if (!uri) throw new Error('uri is required');
  const target = server
    ? { name: server, client: await connect(server, (await loadConfig())[server] ?? { command: '' }) }
    : await anyClient();
  const result = (await requestOn(target.client, 'resources/read', { uri })) as {
    contents?: Array<{ uri?: string; mimeType?: string; text?: string; blob?: string }>;
  };
  const parts = (result.contents ?? []).map(c =>
    c.text !== undefined ? c.text : `(${c.mimeType ?? 'binary'} ${c.blob?.length ?? 0} base64 chars)`);
  return parts.join('\n') || '(empty resource)';
}

// The pending-request map lives on the client; read it back instead of closing
// over a per-call `request` that the reconnect would lose.
function requestOn(client: Client, method: string, params: unknown): Promise<unknown> {
  const id = client.nextId++;
  const payload = JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n';
  return new Promise((resolve, reject) => {
    client.pending.set(id, { resolve, reject });
    const timer = setTimeout(() => {
      if (client.pending.delete(id)) reject(new Error(`MCP ${method} timed out`));
    }, 15_000);
    timer.unref?.();
    client.child.stdin.write(payload);
  });
}

/** Stop every server (tests and shutdown). */
export function shutdownMcp(): void {
  for (const [, c] of clients) c.child.kill('SIGTERM');
  clients.clear();
}

/** Connection state for the sidebar: configured servers and live clients. */
export async function mcpStatus(): Promise<{ configured: string[]; connected: string[] }> {
  let configured: string[] = [];
  try {
    configured = Object.keys(await loadConfig());
  } catch {
    configured = [];
  }
  return { configured, connected: Array.from(clients.keys()) };
}
