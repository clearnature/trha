import { describe, expect, it } from 'vitest';
import { createServer as createHttpsServer } from 'node:https';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fetchStudioInfo } from '../src/main/studioInfo.js';

// studioInfo 走 node:https（生产调度器是自签 loopback 证书 + rejectUnauthorized:false），
// 所以测试桩也必须是 HTTPS 服务器——用仓库内的自签测试证书。
const tls = {
  key: '', cert: '',
};

async function withServer(handler: (port: number) => Promise<void>): Promise<void> {
  if (!tls.key) {
    const fx = path.resolve('test/fixtures');
    tls.key = await readFile(path.join(fx, 'loopback-test-key.pem'), 'utf8');
    tls.cert = await readFile(path.join(fx, 'loopback-test-cert.pem'), 'utf8');
  }
  const srv: Server = createHttpsServer(
    { key: tls.key, cert: tls.cert },
    (_req, res) => {
      res.setHeader('Content-Type', 'application/json');
      res.end(JSON.stringify({ current: '0.1.0', pinned: null, versions: [{ version: '0.1.0', current: true }] }));
    },
  );
  await new Promise<void>(resolve => srv.listen(0, '127.0.0.1', () => resolve()));
  const addr = srv.address();
  const port = addr && typeof addr === 'object' ? addr.port : 0;
  try {
    await handler(port);
  } finally {
    await new Promise<void>(resolve => srv.close(() => resolve()));
  }
}

describe('fetchStudioInfo', () => {
  it('reads current and pinned from /studio/versions', async () => {
    await withServer(async port => {
      const info = await fetchStudioInfo(port);
      expect(info.current).toBe('0.1.0');
      expect(info.pinned).toBeNull();
    });
  });

  it('propagates a non-ok status as an error', async () => {
    await withServer(async port => {
      // withServer 的桩固定回 200；非 200 分支用一个一次性 https 服务器覆盖
      const srv = createHttpsServer(
        {
          key: (await readFile(path.resolve('test/fixtures/loopback-test-key.pem'), 'utf8')),
          cert: (await readFile(path.resolve('test/fixtures/loopback-test-cert.pem'), 'utf8')),
        },
        (_req, res) => { res.statusCode = 500; res.end(); },
      );
      await new Promise<void>(resolve => srv.listen(0, '127.0.0.1', () => resolve()));
      const addr = srv.address();
      const port2 = addr && typeof addr === 'object' ? addr.port : 0;
      try {
        await expect(fetchStudioInfo(port2)).rejects.toThrow(/HTTP 500/);
      } finally {
        await new Promise<void>(resolve => srv.close(() => resolve()));
      }
      void port;
    });
  });

  it('rejects malformed responses', async () => {
    const key = await readFile(path.resolve('test/fixtures/loopback-test-key.pem'), 'utf8');
    const cert = await readFile(path.resolve('test/fixtures/loopback-test-cert.pem'), 'utf8');
    const srv = createHttpsServer({ key, cert }, (_req, res) => { res.end('{"nope":1}'); });
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
