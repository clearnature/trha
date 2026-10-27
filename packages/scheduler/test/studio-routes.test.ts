// /studio static hosting + version/pin surface (one routing rule; loopback).

import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import type { Server } from 'node:http';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { createServer } from '../src/Server/index.js';

let srv: Server;
let base: string;
let stateDir: string;

beforeEach(async () => {
  stateDir = await mkdtemp(path.join(tmpdir(), 'trha-studio-'));
  const { app } = createServer({
    port: 0, token: 'secret-token', haskellHost: 'localhost', haskellPort: 1, stateDir,
  });
  await new Promise<void>(resolve => {
    srv = app.listen(0, '127.0.0.1', () => resolve());
  });
  const addr = srv.address();
  if (addr && typeof addr === 'object') {
    base = `http://127.0.0.1:${addr.port}`;
  } else {
    throw new Error('no port');
  }
});

afterEach(async () => {
  await new Promise<void>(resolve => srv?.close(() => resolve()) ?? resolve());
  // let in-flight async persistence settle before removing the directory
  await new Promise(r => setTimeout(r, 80));
  await rm(stateDir, { recursive: true, force: true }).catch(async () => {
    await new Promise(r => setTimeout(r, 120));
    await rm(stateDir, { recursive: true, force: true }).catch(() => {});
  });
});

describe('/studio hosting and version surface', () => {
  it('serves the studio page under /studio (no token needed)', async () => {
    const res = await fetch(`${base}/studio/`);
    expect(res.status).toBe(200);
    const html = await res.text();
    // Two builds can win here: `packages/app/Web/dist` when it exists, else the
    // legacy Desktop export in `studio-public` (see `webUiBuildDir`). They carry
    // different <title>s, so assert the SPA mount point both of them have.
    expect(html).toContain('<div id="root">');
  });

  it('reports current and pinned versions', async () => {
    const res = await fetch(`${base}/studio/versions`);
    expect(res.status).toBe(200);
    const body = await res.json() as { current: string; pinned: string | null };
    expect(body.current.length).toBeGreaterThan(0);
    expect(body.pinned).toBeNull();
  });

  it('pins a version and persists it to the state dir', async () => {
    const pin = await fetch(`${base}/studio/pin`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ version: '9.9.9' }),
    });
    expect(pin.status).toBe(200);
    const after = await (await fetch(`${base}/studio/versions`)).json() as { pinned: string | null };
    expect(after.pinned).toBe('9.9.9');
    // persisted to pin.json on disk
    const file = await readFile(path.join(stateDir, 'pin.json'), 'utf8');
    expect(JSON.parse(file)).toEqual({ version: '9.9.9' });
  });

  it('same-origin pages get a session cookie and can then write', async () => {
    const origin = `http://127.0.0.1:${new URL(base).port}`;
    // cold read before any cookie: allowed on loopback
    const coldRead = await fetch(`${base}/api/plugins`, { headers: { Origin: origin } });
    expect(coldRead.status).toBe(200);
    // same-origin WRITE without the session cookie is refused
    const writeNoCookie = await fetch(`${base}/api/session/start`, {
      method: 'POST',
      headers: { Origin: origin, 'Content-Type': 'application/json' },
      body: JSON.stringify({ mode: 'standard' }),
    });
    expect(writeNoCookie.status).toBe(401);
    expect((await writeNoCookie.json() as { code?: string }).code).toBe('session');
    // the page itself receives the HttpOnly cookie on first navigation
    const page = await fetch(`${base}/studio/`);
    const setCookie = page.headers.get('set-cookie') ?? '';
    expect(setCookie).toContain('trha_session=');
    const sessionId = setCookie.split('trha_session=')[1]?.split(';')[0] ?? '';
    // with the cookie the same-origin write passes
    const writeOk = await fetch(`${base}/api/session/start`, {
      method: 'POST',
      headers: {
        Origin: origin, 'Content-Type': 'application/json',
        Cookie: `trha_session=${sessionId}`,
      },
      body: JSON.stringify({ mode: 'standard' }),
    });
    expect(writeOk.status).toBe(200);
  });

  it('refuses cross-origin browsers even with a token', async () => {
    const res = await fetch(`${base}/api/plugins`, {
      headers: { Origin: 'http://evil.example', Authorization: 'Bearer secret-token' },
    });
    expect(res.status).toBe(403);
    const body = await res.json() as { code?: string };
    expect(body.code).toBe('origin');
  });

  it('allows origin-less reads on loopback but writes still need the token', async () => {
    const read = await fetch(`${base}/api/plugins`);
    expect(read.status).toBe(200); // loopback origin-less read bypass
    const write = await fetch(`${base}/api/session/start`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ mode: 'standard' }),
    });
    expect(write.status).toBe(401); // origin-less write requires Bearer
    const okWrite = await fetch(`${base}/api/session/start`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: 'Bearer secret-token' },
      body: JSON.stringify({ mode: 'standard' }),
    });
    expect(okWrite.status).toBe(200);
  });

  it('does not swallow the API surface', async () => {
    const health = await fetch(`${base}/health`);
    expect(health.status).toBe(200);
    const deniedWrite = await fetch(`${base}/api/session/start`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ mode: 'standard' }),
    });
    expect(deniedWrite.status).toBe(401);
    const missing = await fetch(`${base}/studio/nope.js`);
    expect(missing.status).toBe(404);
  });
});
