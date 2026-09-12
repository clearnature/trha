// Unix domain socket host-local channel (haskell-agent network-minimalism):
// with socketPath set the scheduler has no TCP surface at all.

import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import type { Server } from 'node:http';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import http from 'node:http';
import { createServer } from '../src/Server/index.js';

let dir: string;
let sock: string;
let srv: Server;

function request(p: string, headers: Record<string, string> = {}): Promise<{ status: number; body: string }> {
  return new Promise((resolve, reject) => {
    const req = http.request({ socketPath: sock, path: p, method: 'GET', headers }, res => {
      let body = '';
      res.on('data', c => { body += c; });
      res.on('end', () => resolve({ status: res.statusCode ?? 0, body }));
    });
    req.on('error', reject);
    req.end();
  });
}

beforeEach(async () => {
  dir = await mkdtemp(path.join(tmpdir(), 'trha-uds-'));
  sock = path.join(dir, 'sched.sock');
  const { app } = createServer({ port: 0, token: 't', haskellHost: 'l', haskellPort: 1, socketPath: sock });
  await new Promise<void>(resolve => { srv = app.listen(sock, () => resolve()); });
});

afterEach(async () => {
  await new Promise<void>(resolve => srv?.close(() => resolve()));
  await rm(dir, { recursive: true, force: true });
});

describe('UDS host channel', () => {
  it('serves health over the socket with no TCP listener', async () => {
    const res = await request('/health');
    expect(res.status).toBe(200);
    expect(JSON.parse(res.body).status).toBe('ok');
  });

  it('allows origin-less reads on the socket (host-local by construction)', async () => {
    const res = await request('/api/sessions');
    expect(res.status).toBe(200);
  });

  it('requires the token for socket writes', async () => {
    const denied = await new Promise<number>((resolve, reject) => {
      const req = http.request(
        { socketPath: sock, path: '/api/session/start', method: 'POST',
          headers: { 'Content-Type': 'application/json' } },
        res => { res.resume(); resolve(res.statusCode ?? 0); });
      req.on('error', reject);
      req.end(JSON.stringify({ mode: 'standard' }));
    });
    expect(denied).toBe(401);
  });
});
