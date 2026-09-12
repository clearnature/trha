// Phase 3: plugin runtime hooks wired into the server lifecycle.

import { describe, it, expect } from 'vitest';
import type { Server } from 'http';
import type { AddressInfo } from 'net';
import type { Express } from 'express';
import { createServer } from '../src/Server/index.js';
import type { Plugin } from '../src/Plugins/Plugin.js';

type Call = { kind: string; payload: unknown };

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

describe('plugin runtime (Phase 3)', () => {
  it('fires lifecycle hooks and lists plugins', async () => {
    const calls: Call[] = [];
    const spy: Plugin = {
      name: 'spy',
      version: '0.0.1',
      description: 'test spy',
      onInit: async () => { calls.push({ kind: 'init', payload: null }); },
      onSessionCreate: async (sessionId) => { calls.push({ kind: 'sessionCreate', payload: sessionId }); },
      onSessionDelete: async (sessionId) => { calls.push({ kind: 'sessionDelete', payload: sessionId }); },
      onMessageSend: async (sessionId, message) => { calls.push({ kind: 'messageSend', payload: { sessionId, message } }); },
      onToolCall: async (sessionId, tool, args) => { calls.push({ kind: 'toolCall', payload: { sessionId, tool, args } }); },
    };

    const { app } = createServer({ port: 0, token: 'dev-token', plugins: [spy] });
    const { base, server } = await listen(app);
    await waitFor(() => calls.some(c => c.kind === 'init'));

    // session create hook
    const start = await fetch(`${base}/api/session/start`, { method: 'POST', headers: auth, body: JSON.stringify({ mode: 'standard' }) });
    const { sessionId } = (await start.json()) as { sessionId: string };
    await waitFor(() => calls.some(c => c.kind === 'sessionCreate' && c.payload === sessionId));

    // message + tool hooks on a fallback step
    await fetch(`${base}/api/agent/step`, { method: 'POST', headers: auth, body: JSON.stringify({ sessionId, message: 'hi' }) });
    await waitFor(() => calls.some(c => c.kind === 'messageSend'));
    await waitFor(() => calls.some(c => c.kind === 'toolCall'));

    // delete hook
    await fetch(`${base}/api/session/${sessionId}`, { method: 'DELETE', headers: auth });
    await waitFor(() => calls.some(c => c.kind === 'sessionDelete' && c.payload === sessionId));

    // /api/plugins lists registered plugins
    const list = await (await fetch(`${base}/api/plugins`, { headers: auth })).json() as Array<{ name: string }>;
    expect(list.map(p => p.name)).toContain('spy');

    server.close();
  });
});
