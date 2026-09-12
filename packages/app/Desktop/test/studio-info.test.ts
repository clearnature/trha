import { describe, expect, it } from 'vitest';
import type { Server } from 'node:http';
import { createServer } from 'node:http';
import { fetchStudioInfo } from '../src/main/studioInfo.js';

const withServer = async (handler: (port: number) => Promise<void>) => {
  const srv: Server = createServer((_req, res) => {
    res.setHeader('Content-Type', 'application/json');
    res.end(JSON.stringify({ current: '0.1.0', pinned: null, versions: [{ version: '0.1.0', current: true }] }));
  });
  await new Promise<void>(resolve => srv.listen(0, '127.0.0.1', () => resolve()));
  const addr = srv.address();
  const port = addr && typeof addr === 'object' ? addr.port : 0;
  try {
    await handler(port);
  } finally {
    await new Promise<void>(resolve => srv.close(() => resolve()));
  }
};

describe('fetchStudioInfo', () => {
  it('reads current and pinned from /studio/versions', async () => {
    await withServer(async port => {
      const info = await fetchStudioInfo(port);
      expect(info.current).toBe('0.1.0');
      expect(info.pinned).toBeNull();
    });
  });

  it('propagates a non-ok status as an error', async () => {
    const srv = createServer((_req, res) => { res.statusCode = 500; res.end(); });
    await new Promise<void>(resolve => srv.listen(0, '127.0.0.1', () => resolve()));
    const addr = srv.address();
    const port = addr && typeof addr === 'object' ? addr.port : 0;
    try {
      await expect(fetchStudioInfo(port)).rejects.toThrow(/HTTP 500/);
    } finally {
      await new Promise<void>(resolve => srv.close(() => resolve()));
    }
  });

  it('rejects malformed responses', async () => {
    const srv = createServer((_req, res) => { res.end('{"nope":1}'); });
    await new Promise<void>(resolve => srv.listen(0, '127.0.0.1', () => resolve()));
    const addr = srv.address();
    const port = addr && typeof addr === 'object' ? addr.port : 0;
    try {
      await expect(fetchStudioInfo(port)).rejects.toThrow(/malformed/);
    } finally {
      await new Promise<void>(resolve => srv.close(() => resolve()));
    }
  });
});
