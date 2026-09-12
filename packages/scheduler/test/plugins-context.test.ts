// Phase 3 C1: Cordis-style activate(ctx)/deactivate with reversible
// ctx.on subscriptions, exercised over the HTTP lifecycle.

import { describe, it, expect } from 'vitest';
import type { Server } from 'http';
import type { AddressInfo } from 'net';
import type { Express } from 'express';
import { createServer } from '../src/Server/index.js';
import type { Plugin, PluginContext } from '../src/Plugins/Plugin.js';

async function listen(app: Express): Promise<{ base: string; server: Server }> {
  const server = await new Promise<Server>((resolve) => {
    const s = app.listen(0, '127.0.0.1', () => resolve(s));
  });
  const { port } = server.address() as AddressInfo;
  return { base: `http://127.0.0.1:${port}`, server };
}

const auth = { 'Content-Type': 'application/json', Authorization: 'Bearer dev-token' } as Record<string, string>;

async function waitFor(fn: () => boolean, timeoutMs = 2000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (fn()) return;
    await new Promise(r => setTimeout(r, 20));
  }
  throw new Error('timed out waiting for condition');
}

async function startSession(base: string): Promise<string> {
  const res = await fetch(`${base}/api/session/start`, { method: 'POST', headers: auth, body: JSON.stringify({ mode: 'standard' }) });
  const { sessionId } = (await res.json()) as { sessionId: string };
  return sessionId;
}

describe('plugin ctx/effect (Phase 3 C1)', () => {
  it('subscribes on activate and unsubscribes on unregister', async () => {
    const seen: string[] = [];
    let deactivated = false;

    const spy: Plugin = {
      name: 'ctx-spy',
      version: '1.0.0',
      description: 'ctx spy',
      activate(ctx: PluginContext) {
        ctx.on('session:created', (data) => {
          seen.push((data as { sessionId: string }).sessionId);
        });
      },
      deactivate: async () => { deactivated = true; },
    };

    const { app } = createServer({ port: 0, token: 'dev-token', plugins: [spy] });
    const { base, server } = await listen(app);

    // activate ran (via register) and the subscription works
    const sid1 = await startSession(base);
    await waitFor(() => seen.includes(sid1));

    // unregister runs deactivate and releases ctx.on subscriptions
    const removed = await fetch(`${base}/api/plugins/ctx-spy`, { method: 'DELETE', headers: auth });
    expect(removed.status).toBe(200);
    expect(deactivated).toBe(true);

    // new sessions must no longer reach the plugin
    const sid2 = await startSession(base);
    await new Promise(r => setTimeout(r, 120));
    expect(seen).not.toContain(sid2);

    server.close();
  });
});
