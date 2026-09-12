// Phase 3: dynamic (declarative) plugin registration over HTTP.

import { describe, it, expect } from 'vitest';
import type { Server } from 'http';
import type { AddressInfo } from 'net';
import type { Express } from 'express';
import { createServer } from '../src/Server/index.js';

async function listen(app: Express): Promise<{ base: string; server: Server }> {
  const server = await new Promise<Server>((resolve) => {
    const s = app.listen(0, '127.0.0.1', () => resolve(s));
  });
  const { port } = server.address() as AddressInfo;
  return { base: `http://127.0.0.1:${port}`, server };
}

const auth = { 'Content-Type': 'application/json', Authorization: 'Bearer dev-token' } as Record<string, string>;

async function listPlugins(base: string): Promise<Array<{ name: string }>> {
  const res = await fetch(`${base}/api/plugins`, { headers: auth });
  return (await res.json()) as Array<{ name: string }>;
}

describe('dynamic plugin management (Phase 3)', () => {
  it('registers, lists, then unregisters a declarative plugin', async () => {
    const { app } = createServer({ port: 0, token: 'dev-token' });
    const { base, server } = await listen(app);

    const created = await fetch(`${base}/api/plugins`, {
      method: 'POST', headers: auth,
      body: JSON.stringify({ name: 'memo', version: '1.0.0', description: 'memory vault' }),
    });
    expect(created.status).toBe(201);

    expect((await listPlugins(base)).map(p => p.name)).toContain('memo');

    const removed = await fetch(`${base}/api/plugins/memo`, { method: 'DELETE', headers: auth });
    expect(removed.status).toBe(200);
    expect((await listPlugins(base)).map(p => p.name)).not.toContain('memo');

    server.close();
  });

  it('rejects duplicate registration and unknown removal', async () => {
    const { app } = createServer({ port: 0, token: 'dev-token' });
    const { base, server } = await listen(app);

    const body = JSON.stringify({ name: 'dup', version: '0.1.0', description: 'x' });
    expect((await fetch(`${base}/api/plugins`, { method: 'POST', headers: auth, body })).status).toBe(201);
    expect((await fetch(`${base}/api/plugins`, { method: 'POST', headers: auth, body })).status).toBe(409);
    expect((await fetch(`${base}/api/plugins/nope`, { method: 'DELETE', headers: auth })).status).toBe(404);

    server.close();
  });
});
