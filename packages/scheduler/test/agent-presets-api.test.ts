// End-to-end checks for the agent-preset seam: the endpoints and the validation
// that guards them. Uses the real `createServer` so a regression in wiring (not
// just in `agentPresets.ts`) shows up here.
import { describe, expect, it } from 'vitest';
import type { Server } from 'node:http';
import type { AddressInfo } from 'node:net';
import type { Express } from 'express';
import { createServer } from '../src/Server/index.js';

async function listen(app: Express): Promise<{ base: string; server: Server }> {
  const server = await new Promise<Server>((resolve) => {
    const s = app.listen(0, '127.0.0.1', () => resolve(s));
  });
  const { port } = server.address() as AddressInfo;
  return { base: `http://127.0.0.1:${port}`, server };
}

const auth = { Authorization: 'Bearer dev-token' } as Record<string, string>;
const json = { ...auth, 'Content-Type': 'application/json' };

describe('agent preset endpoints', () => {
  it('lists the four presets and resolves one by id', async () => {
    const { app } = createServer({ port: 0, token: 'dev-token' });
    const { base, server } = await listen(app);
    try {
      const all = (await (await fetch(`${base}/api/agent/presets`, { headers: auth })).json()) as {
        default: string;
        presets: Array<{ name: string }>;
      };
      expect(all.default).toBe('standard');
      expect(all.presets.map(p => p.name).sort())
        .toEqual(['cordis', 'minimal', 'ptc', 'standard']);

      const one = (await (await fetch(`${base}/api/agent/presets?id=minimal`, { headers: auth })).json()) as {
        preset: { hasWebSearch: boolean; tools: string[] };
      };
      expect(one.preset.hasWebSearch).toBe(false);
      expect(one.preset.tools).not.toContain('subagent');
    } finally {
      server.close();
    }
  });

  it('refuses an unknown preset id', async () => {
    const { app } = createServer({ port: 0, token: 'dev-token' });
    const { base, server } = await listen(app);
    try {
      const res = await fetch(`${base}/api/agent/presets?id=nope`, { headers: auth });
      expect(res.status).toBe(404);
    } finally {
      server.close();
    }
  });

  it('accepts a known agentPreset on session start and refuses an unknown one', async () => {
    const { app } = createServer({ port: 0, token: 'dev-token' });
    const { base, server } = await listen(app);
    try {
      const ok = await fetch(`${base}/api/session/start`, {
        method: 'POST',
        headers: json,
        body: JSON.stringify({ agentPreset: 'minimal' }),
      });
      expect(ok.status).toBe(200);

      const bad = await fetch(`${base}/api/session/start`, {
        method: 'POST',
        headers: json,
        body: JSON.stringify({ agentPreset: 'nope' }),
      });
      expect(bad.status).toBe(400);
    } finally {
      server.close();
    }
  });
});
