// Right-panel preview: one workspace file, bounded and confined.

import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import type { AddressInfo } from 'node:net';
import type { Server } from 'node:http';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { createServer } from '../src/Server/index.js';

let dir: string;
let server: Server | null = null;
let stopScheduler: (() => void) | null = null;
let base = '';
let savedWorkspace: string | undefined;

beforeEach(async () => {
  dir = await mkdtemp(path.join(tmpdir(), 'trha-file-'));
  savedWorkspace = process.env.TRHA_WORKSPACE;
  process.env.TRHA_WORKSPACE = dir;
  await mkdir(path.join(dir, 'src'), { recursive: true });
  await writeFile(path.join(dir, 'src', 'a.txt'), 'hello\n', 'utf8');

  const { app, stop } = createServer({
    port: 0, token: 'dev-token', haskellHost: '127.0.0.1', haskellPort: 1,
  });
  stopScheduler = stop;
  server = await new Promise<Server>(resolve => {
    const srv = app.listen(0, '127.0.0.1', () => resolve(srv));
  });
  base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
});

afterEach(async () => {
  stopScheduler?.();
  server?.close();
  server = null;
  stopScheduler = null;
  if (savedWorkspace === undefined) delete process.env.TRHA_WORKSPACE;
  else process.env.TRHA_WORKSPACE = savedWorkspace;
  await rm(dir, { recursive: true, force: true });
});

describe('GET /api/workspace/file', () => {
  it('returns a file inside the workspace', async () => {
    const res = await fetch(`${base}/api/workspace/file?path=${encodeURIComponent('src/a.txt')}`);
    expect(res.status).toBe(200);
    const body = await res.json() as { path: string; text: string; size: number };
    expect(body.path).toBe('src/a.txt');
    expect(body.text).toBe('hello\n');
    expect(body.size).toBe(6);
  });

  it('rejects traversal outside the workspace', async () => {
    const res = await fetch(`${base}/api/workspace/file?path=${encodeURIComponent('../etc/passwd')}`);
    expect(res.status).toBe(403);
  });

  it('404s a missing file and 400s a directory', async () => {
    const missing = await fetch(`${base}/api/workspace/file?path=nope.txt`);
    expect(missing.status).toBe(404);
    const directory = await fetch(`${base}/api/workspace/file?path=src`);
    expect(directory.status).toBe(400);
  });

  it('400s without a path', async () => {
    const res = await fetch(`${base}/api/workspace/file`);
    expect(res.status).toBe(400);
  });
});
