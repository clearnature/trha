// The browser entry point: `/` used to be "Cannot GET /" because only /api/*
// and /studio were routed. It now redirects to the studio pages.

import type { AddressInfo } from 'node:net';
import type { Server } from 'node:http';
import { describe, it, expect, afterEach } from 'vitest';
import { createServer } from '../src/Server/index.js';

let server: Server | null = null;
let stopScheduler: (() => void) | null = null;

afterEach(() => {
  stopScheduler?.();
  server?.close();
  server = null;
  stopScheduler = null;
});

async function listen(): Promise<string> {
  const { app, stop } = createServer({
    port: 0, token: 'dev-token', haskellHost: '127.0.0.1', haskellPort: 1,
  });
  stopScheduler = stop;
  server = await new Promise<Server>(resolve => {
    const srv = app.listen(0, '127.0.0.1', () => resolve(srv));
  });
  return `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
}

describe('root route', () => {
  it('redirects / to /studio/', async () => {
    const base = await listen();
    const res = await fetch(`${base}/`, { redirect: 'manual' });
    expect(res.status).toBe(302);
    expect(res.headers.get('location')).toBe('/studio/');
  });

  it('keeps /health on the API', async () => {
    const base = await listen();
    const res = await fetch(`${base}/health`);
    expect(res.status).toBe(200);
    expect(await res.json()).toMatchObject({ status: 'ok' });
  });
});
