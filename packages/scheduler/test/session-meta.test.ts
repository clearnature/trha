// Session rename / tag: the metadata is user-facing only, survives a
// scheduler restart (stateDir), and is visible through /api/sessions.
import { describe, it, expect, afterEach } from 'vitest';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { once } from 'node:events';
import type { AddressInfo } from 'node:net';
import { createServer, type ServerConfig } from '../src/Server/index.js';

const TOKEN = 'session-meta-token';
const auth = { Authorization: `Bearer ${TOKEN}`, 'Content-Type': 'application/json' };

const dirs: string[] = [];
const servers: { close(cb?: () => void): void }[] = [];

async function tempDir(): Promise<string> {
  const dir = await mkdtemp(path.join(tmpdir(), 'trha-meta-'));
  dirs.push(dir);
  return dir;
}

async function startOn(dir: string): Promise<number> {
  const config: ServerConfig = {
    port: 0,
    host: '127.0.0.1',
    token: TOKEN,
    haskellHost: '127.0.0.1',
    haskellPort: 1,
    stateDir: dir,
  };
  const { app } = createServer(config);
  const server = app.listen(0, '127.0.0.1');
  servers.push(server);
  await once(server, 'listening');
  return (server.address() as AddressInfo).port;
}

async function closeAll(): Promise<void> {
  for (const s of servers.splice(0)) {
    await new Promise<void>((resolve) => s.close(() => resolve()));
  }
}

afterEach(async () => {
  await closeAll();
  for (const d of dirs.splice(0)) await rm(d, { recursive: true, force: true });
});

async function startSession(port: number): Promise<string> {
  const res = await fetch(`http://127.0.0.1:${port}/api/session/start`, {
    method: 'POST', headers: auth, body: JSON.stringify({ mode: 'standard', permissionMode: 'yolo' }),
  });
  const body = (await res.json()) as { sessionId: string };
  return body.sessionId;
}

describe('session meta', () => {
  it('renames and tags a session, and persists both', async () => {
    const dir = await tempDir();
    let port = await startOn(dir);
    const sessionId = await startSession(port);

    const res = await fetch(`http://127.0.0.1:${port}/api/session/${sessionId}/meta`, {
      method: 'POST', headers: auth,
      body: JSON.stringify({ title: 'Port TUI', tags: ['tui', 'port'] }),
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { title: string; tags: string[] };
    expect(body.title).toBe('Port TUI');
    expect(body.tags).toEqual(['tui', 'port']);

    const list = (await (await fetch(`http://127.0.0.1:${port}/api/sessions`, {
      headers: auth,
    })).json()) as Array<{ id: string; title?: string; tags?: string[] }>;
    const row = list.find((s) => s.id === sessionId);
    expect(row?.title).toBe('Port TUI');
    expect(row?.tags).toEqual(['tui', 'port']);

    // A restart on the same state dir restores the metadata.
    await closeAll();
    port = await startOn(dir);
    const list2 = (await (await fetch(`http://127.0.0.1:${port}/api/sessions`, {
      headers: auth,
    })).json()) as Array<{ id: string; title?: string; tags?: string[] }>;
    const row2 = list2.find((s) => s.id === sessionId);
    expect(row2?.title).toBe('Port TUI');
    expect(row2?.tags).toEqual(['tui', 'port']);
  });

  it('rejects an unknown session', async () => {
    const dir = await tempDir();
    const port = await startOn(dir);
    const res = await fetch(`http://127.0.0.1:${port}/api/session/nope/meta`, {
      method: 'POST', headers: auth, body: JSON.stringify({ title: 'x' }),
    });
    expect(res.status).toBe(404);
  });
});
