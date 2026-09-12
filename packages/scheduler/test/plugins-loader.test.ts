// Phase 3 A1: plugin directory loader + server pluginsDir wiring.

import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { describe, it, expect } from 'vitest';
import type { Server } from 'http';
import type { AddressInfo } from 'net';
import type { Express } from 'express';
import { loadPluginsFrom } from '../src/Plugins/loader.js';
import { createServer } from '../src/Server/index.js';

async function listen(app: Express): Promise<{ base: string; server: Server }> {
  const server = await new Promise<Server>((resolve) => {
    const s = app.listen(0, '127.0.0.1', () => resolve(s));
  });
  const { port } = server.address() as AddressInfo;
  return { base: `http://127.0.0.1:${port}`, server };
}

const auth = { Authorization: 'Bearer dev-token' } as Record<string, string>;

async function waitFor(fn: () => Promise<boolean> | boolean, timeoutMs = 3000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await fn()) return;
    await new Promise(r => setTimeout(r, 30));
  }
  throw new Error('timed out waiting for condition');
}

describe('plugin loader (Phase 3 A1)', () => {
  it('loads plugin modules with a default export and skips bad files', async () => {
    const dir = await mkdtemp(path.join(tmpdir(), 'trha-plugins-'));
    try {
      await writeFile(path.join(dir, 'good.mjs'), `
        export default {
          name: 'disk-plugin',
          version: '0.1.0',
          description: 'loaded from disk',
          activate(ctx) { ctx.on('session:created', () => {}); },
        };
      `);
      await writeFile(path.join(dir, 'bad.mjs'), `export default { nope: true };`);
      await writeFile(path.join(dir, 'readme.txt'), 'ignored');

      const plugins = await loadPluginsFrom(dir);
      expect(plugins.map(p => p.name)).toEqual(['disk-plugin']);
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });

  it('registers directory plugins on the server and lists them', async () => {
    const dir = await mkdtemp(path.join(tmpdir(), 'trha-plugins-'));
    try {
      await writeFile(path.join(dir, 'disk2.mjs'), `
        export default {
          name: 'disk-two',
          version: '0.2.0',
          description: 'second from disk',
        };
      `);
      const { app } = createServer({ port: 0, token: 'dev-token', pluginsDir: dir });
      const { base, server } = await listen(app);

      await waitFor(async () => {
        const list = (await (await fetch(`${base}/api/plugins`, { headers: auth })).json()) as Array<{ name: string }>;
        return list.some(p => p.name === 'disk-two');
      });

      server.close();
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });
});
