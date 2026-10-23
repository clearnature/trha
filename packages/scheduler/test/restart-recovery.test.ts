// Server-level session recovery: the desktop shell now always passes
// TRHA_STATE_DIR, so the scheduler must actually persist on create and reload
// on startup. The unit tests in state-store.test.ts cover the store itself;
// these drive the real HTTP surface twice on the same directory.
import { describe, it, expect, afterEach } from 'vitest';
import { mkdtemp, readdir, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { once } from 'node:events';
import type { AddressInfo } from 'node:net';
import { createServer, type ServerConfig } from '../src/Server/index.js';
import { saveSession } from '../src/Server/stateStore.js';

const TOKEN = 'restart-recovery-token';
const auth = { Authorization: `Bearer ${TOKEN}`, 'Content-Type': 'application/json' };

const dirs: string[] = [];
const servers: { close(cb?: () => void): void }[] = [];

async function tempDir(): Promise<string> {
  const dir = await mkdtemp(path.join(tmpdir(), 'trha-state-'));
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

async function waitFor<T>(probe: () => Promise<T | undefined>, timeoutMs = 3000): Promise<T> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const value = await probe();
    if (value !== undefined) return value;
    await new Promise(resolve => setTimeout(resolve, 20));
  }
  throw new Error(`waitFor timed out after ${timeoutMs}ms`);
}

afterEach(async () => {
  for (const server of servers.splice(0)) {
    await new Promise<void>(resolve => server.close(() => resolve()));
  }
  for (const dir of dirs.splice(0)) {
    await rm(dir, { recursive: true, force: true });
  }
});

describe('session persistence through the HTTP server', () => {
  it('writes a session file when a session is created', async () => {
    const dir = await tempDir();
    const port = await startOn(dir);

    const created = await fetch(`http://127.0.0.1:${port}/api/session/start`, {
      method: 'POST',
      headers: auth,
      body: JSON.stringify({ mode: 'standard' }),
    }).then(r => r.json() as Promise<{ sessionId: string }>);

    expect(created.sessionId).toBeTruthy();

    const record = await waitFor(async () => {
      const names = await readdir(dir).catch(() => [] as string[]);
      const name = names.find(n => n.endsWith('.json'));
      if (!name) return undefined;
      return JSON.parse(await readFile(path.join(dir, name), 'utf8')) as {
        v: number;
        sessionId: string;
      };
    });

    expect(record.v).toBe(1);
    expect(record.sessionId).toBe(created.sessionId);
  });

  it('restores a persisted session after a restart', async () => {
    const dir = await tempDir();
    const sessionId = 'session-restart-probe';

    // What a previous run would have left behind.
    await saveSession(dir, {
      id: sessionId,
      mode: 'standard',
      messages: [{ role: 'user', content: 'hello before restart' }],
      pendingApproval: null,
      createdAt: new Date('2026-01-01T00:00:00Z'),
    });

    const firstPort = await startOn(dir);
    const firstList = await waitFor(async () => {
      const items = await fetch(`http://127.0.0.1:${firstPort}/api/sessions`, { headers: auth })
        .then(r => r.json() as Promise<{ id: string }[]>);
      return items.some(s => s.id === sessionId) ? items : undefined;
    });
    expect(firstList.some(s => s.id === sessionId)).toBe(true);

    // Restart on the same state directory (new process in production).
    servers.splice(0).forEach(server => server.close());
    const secondPort = await startOn(dir);

    const secondList = await waitFor(async () => {
      const items = await fetch(`http://127.0.0.1:${secondPort}/api/sessions`, { headers: auth })
        .then(r => r.json() as Promise<{ id: string }[]>);
      return items.some(s => s.id === sessionId) ? items : undefined;
    });
    expect(secondList.some(s => s.id === sessionId)).toBe(true);

    const body = await fetch(
      `http://127.0.0.1:${secondPort}/api/session/${sessionId}/messages`,
      { headers: auth },
    ).then(r => r.json() as Promise<{ messages: { role: string; content: string }[] }>);

    expect(body.messages).toHaveLength(1);
    expect(body.messages[0]).toMatchObject({ role: 'user', content: 'hello before restart' });
  });
});
