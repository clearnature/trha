// `working_directory` must change what the other tools see.
//
// The tool used to store the path (and report it back) while bash/read/write
// kept using the workspace root — a setting that looks applied and is not. This
// drives the real loop: switch directory, then read and run through it.

import express from 'express';
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import type { Server } from 'http';
import type { AddressInfo } from 'net';
import { mkdtemp, mkdir, rm, writeFile } from 'node:fs/promises';
import { realpathSync } from 'node:fs';
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

interface Round { name: string; args: Record<string, unknown> }

function scriptKernel(rounds: Round[]) {
  const kernel = express();
  kernel.use(express.json());
  let i = 0;
  kernel.post('/session/start', (_q, res) => res.json({}));
  kernel.post('/v1/chat/completions', (req, res) => {
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
    res.json({ choices: [{ message: { role: 'assistant', content: results.join('\n---\n'), finish_reason: 'stop' } }] });
  });
  return kernel;
}

describe('working_directory applies to the other tools', () => {
  let dir: string;
  beforeEach(async () => {
    dir = await mkdtemp(path.join(tmpdir(), 'trha-cwd-'));
    process.env.TRHA_WORKSPACE = dir;
    process.env.TRHA_SCHEDULE_TICK_MS = '0';
    await mkdir(path.join(dir, 'sub'), { recursive: true });
    await writeFile(path.join(dir, 'sub', 'x.txt'), 'inner-file', 'utf8');
    await writeFile(path.join(dir, 'x.txt'), 'outer-file', 'utf8');
  });
  afterEach(async () => {
    delete process.env.TRHA_WORKSPACE;
    delete process.env.TRHA_SCHEDULE_TICK_MS;
    await rm(dir, { recursive: true, force: true });
  });

  it('read and bash resolve against the session cwd, not the workspace root', async () => {
    const kernel = scriptKernel([
      { name: 'working_directory', args: { path: 'sub' } },
      { name: 'read', args: { path: 'x.txt' } },
      { name: 'bash', args: { command: 'pwd' } },
    ]);
    const kernelServer = await listen(kernel);
    const { app, stop } = createServer({
      port: 0, token: 'dev-token', haskellHost: '127.0.0.1', haskellPort: kernelServer.port,
      stateDir: path.join(dir, 'state'),
    });
    const schedulerServer = await listen(app);
    const base = `http://127.0.0.1:${schedulerServer.port}`;

    const start = await fetch(`${base}/api/session/start`, {
      method: 'POST', headers: auth, body: JSON.stringify({ mode: 'standard', permissionMode: 'yolo' }),
    });
    const { sessionId } = (await start.json()) as { sessionId: string };
    const step = await fetch(`${base}/api/agent/step`, {
      method: 'POST', headers: auth, body: JSON.stringify({ sessionId, message: 'switch then read' }),
    });
    const body = (await step.json()) as { messages: Array<{ role: string; content: string }> };
    const toolResults = body.messages.filter(m => m.role === 'tool').map(m => m.content);

    expect(toolResults[0]).toMatch(/cwd is now .*sub/);
    // the file inside sub/, not the one at the root with the same name
    expect(toolResults[1]).toContain('inner-file');
    expect(toolResults[1]).not.toContain('outer-file');
    // bash runs where the session says it runs
    expect(toolResults[2]).toContain(path.join(realpathOr(dir), 'sub'));

    stop(); kernelServer.server.close(); schedulerServer.server.close();
  });

  // The tool is offered to the model as `bash`; it used to run under Node's
  // default `/bin/sh` (dash on Debian), where bash syntax is a syntax error.
  it.skipIf(process.platform === 'win32')(
    'bash is really bash, and it keeps the inherited PATH',
    async () => {
      const kernel = scriptKernel([
        { name: 'bash', args: { command: '[[ -n x ]] && echo bashy-ok' } },
        { name: 'bash', args: { command: 'echo "ver=${BASH_VERSION:-none}"' } },
        { name: 'bash', args: { command: 'command -v node' } },
      ]);
      const kernelServer = await listen(kernel);
      const { app, stop } = createServer({
        port: 0, token: 'dev-token', haskellHost: '127.0.0.1', haskellPort: kernelServer.port,
        stateDir: path.join(dir, 'state'),
      });
      const schedulerServer = await listen(app);
      const base = `http://127.0.0.1:${schedulerServer.port}`;

      const start = await fetch(`${base}/api/session/start`, {
        method: 'POST', headers: auth, body: JSON.stringify({ mode: 'standard', permissionMode: 'yolo' }),
      });
      const { sessionId } = (await start.json()) as { sessionId: string };
      const step = await fetch(`${base}/api/agent/step`, {
        method: 'POST', headers: auth, body: JSON.stringify({ sessionId, message: 'bash checks' }),
      });
      const body = (await step.json()) as { messages: Array<{ role: string; content: string }> };
      const results = body.messages.filter(m => m.role === 'tool').map(m => m.content);

      // bash-only syntax, and a clean exit (dash reported `not found`, 127)
      expect(results[0]).toContain('bashy-ok');
      expect(results[0]).toMatch(/^exit 0/);
      // BASH_VERSION is set by bash itself
      expect(results[1]).not.toContain('ver=none');
      // ...and the shell is NOT a login shell: a profile must not rewrite PATH,
      // which on this machine swaps an fnm node for the system one.
      const which = (results[2] ?? '').replace(/^exit \d+\n/, '').trim();
      expect(realpathSync(which)).toBe(realpathSync(process.execPath));

      stop(); kernelServer.server.close(); schedulerServer.server.close();
    },
  );
});

/** macOS-style /private symlinks are not an issue here, but keep it honest. */
function realpathOr(p: string): string {
  return p;
}
