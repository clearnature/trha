// "UNCHANGED means no write" has to hold on disk, not just in memory.
//
// The tool already refuses to touch state for an identical list; the loop then
// used to persist the session anyway, churning the file (and its mtime) for
// nothing.
//
// The kernel is called once per model round, which is exactly between the tool
// result and the next request — so it samples the session file's mtime at each
// boundary. Round 2 sees the mtime after the real write; round 3, after the
// identical repeat, must see the same number.

import express from 'express';
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import type { Server } from 'http';
import type { AddressInfo } from 'net';
import { mkdtemp, rm, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { createServer } from '../src/Server/index.js';

const auth = { 'Content-Type': 'application/json', Authorization: 'Bearer dev-token' } as Record<string, string>;

async function listen(app: express.Express): Promise<{ port: number; server: Server }> {
  const s = await new Promise<Server>(resolve => {
    const srv = app.listen(0, '127.0.0.1', () => resolve(srv));
  });
  return { port: (s.address() as AddressInfo).port, server: s };
}

const TODO = [{ text: 'only task', status: 'pending' }];
interface Round { name: string; args: Record<string, unknown> }

const wait = (ms: number): Promise<void> => new Promise(r => setTimeout(r, ms));

describe('UNCHANGED todo does not rewrite the session', () => {
  let dir: string;
  beforeEach(async () => { dir = await mkdtemp(path.join(tmpdir(), 'trha-nowrite-')); });
  afterEach(async () => { await rm(dir, { recursive: true, force: true }); });

  it('leaves the file untouched for an identical rewrite', async () => {
    const stateDir = path.join(dir, 'state');
    const mtimes: number[] = [];
    let sessionFile = '';

    const rounds: Round[] = [
      { name: 'todo_write', args: { todos: TODO } },                             // real write
      { name: 'todo_write', args: { todos: TODO } },                             // identical
      { name: 'todo_write', args: { todos: [{ text: 'only task', status: 'completed' }] } }, // real write
    ];

    const kernel = express();
    kernel.use(express.json());
    let i = 0;
    kernel.post('/session/start', (_q, res) => res.json({}));
    kernel.post('/v1/chat/completions', async (req, res) => {
      // sample the file as the loop is about to ask again
      try {
        const st = await stat(sessionFile);
        mtimes.push(st.mtimeMs);
      } catch {
        mtimes.push(-1);
      }
      await wait(25);   // make a rewrite visibly change the timestamp
      const msgs = req.body.messages as Array<{ role: string; content: string }>;
      const results = msgs.filter(m => m.role === 'tool').map(m => m.content);
      const next = rounds[i];
      if (next) {
        i += 1;
        return res.json({
          choices: [{
            message: {
              role: 'assistant', content: '',
              tool_calls: [{ id: `c${i}`, type: 'function', function: { name: next.name, arguments: JSON.stringify(next.args) } }],
            },
            finish_reason: 'tool_calls',
          }],
        });
      }
      res.json({ choices: [{ message: { role: 'assistant', content: results.join(' | '), finish_reason: 'stop' } }] });
    });

    const kernelServer = await listen(kernel);
    const { app, stop } = createServer({
      port: 0, token: 'dev-token', haskellHost: '127.0.0.1', haskellPort: kernelServer.port, stateDir,
    });
    const schedulerServer = await listen(app);
    const base = `http://127.0.0.1:${schedulerServer.port}`;

    const start = await fetch(`${base}/api/session/start`, {
      method: 'POST', headers: auth, body: JSON.stringify({ mode: 'standard' }),
    });
    const { sessionId } = (await start.json()) as { sessionId: string };
    sessionFile = path.join(stateDir, `${sessionId}.json`);

    const step = await fetch(`${base}/api/agent/step`, {
      method: 'POST', headers: auth, body: JSON.stringify({ sessionId, message: 'do it' }),
    });
    const body = (await step.json()) as { reply?: string };

    expect(body.reply).toContain('UNCHANGED');
    // samples: [0] first call (file exists, no write yet), [1] after write A,
    // [2] after the identical repeat, [3] after the second real write
    expect(mtimes.length).toBeGreaterThanOrEqual(4);
    expect(mtimes[2]).toBe(mtimes[1]);          // UNCHANGED wrote nothing
    expect(mtimes[3]).toBeGreaterThan(mtimes[2]!); // the real change did write

    stop(); kernelServer.server.close(); schedulerServer.server.close();
  });
});
