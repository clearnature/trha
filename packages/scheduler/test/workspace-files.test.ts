// Sidebar "Files": a bounded top-level listing of the session workspace.

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
  dir = await mkdtemp(path.join(tmpdir(), 'trha-files-'));
  savedWorkspace = process.env.TRHA_WORKSPACE;
  process.env.TRHA_WORKSPACE = dir;
  await mkdir(path.join(dir, 'src'), { recursive: true });
  await mkdir(path.join(dir, 'node_modules'), { recursive: true });
  await mkdir(path.join(dir, '.git'), { recursive: true });
  await writeFile(path.join(dir, 'b.md'), '# b\n', 'utf8');
  await writeFile(path.join(dir, 'a.txt'), 'a\n', 'utf8');

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

describe('GET /api/workspace/files', () => {
  it('lists the workspace top level, sorted, without VCS/build noise', async () => {
    const res = await fetch(`${base}/api/workspace/files`);
    expect(res.status).toBe(200);
    const body = await res.json() as { root: string; files: { path: string; dir: boolean }[] };
    expect(body.root).toBe(dir);
    expect(body.files.map(f => f.path)).toEqual(['a.txt', 'b.md', 'src/']);
    expect(body.files.find(f => f.path === 'src/')?.dir).toBe(true);
  });

  it('honours the limit', async () => {
    const res = await fetch(`${base}/api/workspace/files?limit=2`);
    const body = await res.json() as { files: unknown[] };
    expect(body.files).toHaveLength(2);
  });
});
