// The kernel owns the approval gate; the scheduler delegates to it.
//
// Before this, `requireApproval` lived only in the scheduler's own session
// record: a kernel restart forgot it, and nothing stopped a step from running
// "past" a pending decision. These tests pin the delegation: the scheduler must
// actually call the kernel's /session/:id/approval and /session/:id/decision,
// and it must keep working when the kernel is down (local fallback).

import express from 'express';
import { describe, it, expect } from 'vitest';
import type { Server } from 'http';
import type { AddressInfo } from 'net';
import { createServer } from '../src/Server/index.js';

async function listen(app: express.Express): Promise<{ port: number; server: Server }> {
  const server = await new Promise<Server>((resolve) => {
    const s = app.listen(0, '127.0.0.1', () => resolve(s));
  });
  const { port } = server.address() as AddressInfo;
  return { port, server };
}

const auth = { 'Content-Type': 'application/json', Authorization: 'Bearer dev-token' } as Record<string, string>;

interface GateCall { kind: 'approval' | 'decision'; body: Record<string, unknown> }

/** A fake kernel that records the gate calls it receives. */
function fakeKernel(gate: GateCall[], chats: Record<string, unknown>[] = []) {
  const kernel = express();
  kernel.use(express.json());
  kernel.post('/session/start', (_req, res) => { res.json({ sessionId: 'x', resumed: false }); });
  kernel.post('/session/:id/approval', (req, res) => {
    gate.push({ kind: 'approval', body: req.body as Record<string, unknown> });
    res.json({ status: 'awaiting_approval' });
  });
  kernel.post('/session/:id/decision', (req, res) => {
    gate.push({ kind: 'decision', body: req.body as Record<string, unknown> });
    res.json({ status: (req.body as { approve?: boolean }).approve ? 'approved' : 'denied' });
  });
  kernel.post('/v1/chat/completions', (req, res) => {
    chats.push(req.body as Record<string, unknown>);
    res.json({ choices: [{ message: { role: 'assistant', content: 'done', finish_reason: 'stop' } }] });
  });
  return kernel;
}

async function waitFor(predicate: () => boolean, timeoutMs = 1000): Promise<void> {
  const started = Date.now();
  while (!predicate()) {
    if (Date.now() - started > timeoutMs) throw new Error('timed out waiting for the kernel gate call');
    await new Promise(r => setTimeout(r, 10));
  }
}

describe('approval gate delegation to the kernel', () => {
  it('parks the command kernel-side on requireApproval', async () => {
    const gate: GateCall[] = [];
    const kernelServer = await listen(fakeKernel(gate));
    const { app } = createServer({
      port: 0, token: 'dev-token',
      haskellHost: '127.0.0.1', haskellPort: kernelServer.port,
    });
    const schedulerServer = await listen(app);
    const base = `http://127.0.0.1:${schedulerServer.port}`;

    const start = await fetch(`${base}/api/session/start`, { method: 'POST', headers: auth, body: JSON.stringify({ mode: 'standard' }) });
    const { sessionId } = (await start.json()) as { sessionId: string };

    const step = await fetch(`${base}/api/agent/step`, {
      method: 'POST', headers: auth,
      body: JSON.stringify({ sessionId, message: 'rm -rf build', requireApproval: true }),
    });
    const body = (await step.json()) as { status?: string; pending?: { message?: string } };
    // shell contract unchanged
    expect(body.status).toBe('awaiting_approval');
    expect(body.pending?.message).toBe('rm -rf build');

    // ...and the kernel was told, so it holds the barrier
    await waitFor(() => gate.some(c => c.kind === 'approval'));
    const parked = gate.find(c => c.kind === 'approval');
    expect(parked?.body.message).toBe('rm -rf build');

    kernelServer.server.close();
    schedulerServer.server.close();
  });

  it('releases the kernel gate on approve and on deny', async () => {
    const gate: GateCall[] = [];
    const kernelServer = await listen(fakeKernel(gate));
    const { app } = createServer({
      port: 0, token: 'dev-token',
      haskellHost: '127.0.0.1', haskellPort: kernelServer.port,
    });
    const schedulerServer = await listen(app);
    const base = `http://127.0.0.1:${schedulerServer.port}`;

    const start = await fetch(`${base}/api/session/start`, { method: 'POST', headers: auth, body: JSON.stringify({ mode: 'standard' }) });
    const { sessionId } = (await start.json()) as { sessionId: string };

    await fetch(`${base}/api/agent/step`, {
      method: 'POST', headers: auth,
      body: JSON.stringify({ sessionId, message: 'first', requireApproval: true }),
    });
    await waitFor(() => gate.some(c => c.kind === 'approval'));

    const deny = await fetch(`${base}/api/session/${sessionId}/decision`, {
      method: 'POST', headers: auth, body: JSON.stringify({ approve: false }),
    });
    expect(((await deny.json()) as { status?: string }).status).toBe('denied');
    await waitFor(() => gate.some(c => c.kind === 'decision' && c.body.approve === false));

    // a second gate, approved
    await fetch(`${base}/api/agent/step`, {
      method: 'POST', headers: auth,
      body: JSON.stringify({ sessionId, message: 'second', requireApproval: true }),
    });
    await waitFor(() => gate.filter(c => c.kind === 'approval').length === 2);

    const approve = await fetch(`${base}/api/session/${sessionId}/decision`, {
      method: 'POST', headers: auth, body: JSON.stringify({ approve: true }),
    });
    expect(((await approve.json()) as { status?: string }).status).toBe('approved');
    await waitFor(() => gate.some(c => c.kind === 'decision' && c.body.approve === true));

    kernelServer.server.close();
    schedulerServer.server.close();
  });

  it('replays an approved turn with the provider/model that parked it', async () => {
    const gate: GateCall[] = [];
    const chats: Record<string, unknown>[] = [];
    const kernelServer = await listen(fakeKernel(gate, chats));
    const { app } = createServer({
      port: 0, token: 'dev-token',
      haskellHost: '127.0.0.1', haskellPort: kernelServer.port,
    });
    const schedulerServer = await listen(app);
    const base = `http://127.0.0.1:${schedulerServer.port}`;

    const start = await fetch(`${base}/api/session/start`, { method: 'POST', headers: auth, body: JSON.stringify({ mode: 'standard' }) });
    const { sessionId } = (await start.json()) as { sessionId: string };

    await fetch(`${base}/api/agent/step`, {
      method: 'POST', headers: auth,
      body: JSON.stringify({
        sessionId, message: 'gated', requireApproval: true,
        provider: 'deepseek-anthropic', model: 'deepseek-flash',
      }),
    });
    await waitFor(() => gate.some(c => c.kind === 'approval'));

    await fetch(`${base}/api/session/${sessionId}/decision`, {
      method: 'POST', headers: auth, body: JSON.stringify({ approve: true }),
    });
    await waitFor(() => chats.length > 0);

    // The replay must not fall back to the kernel's in-use provider.
    expect(chats[0]?.provider).toBe('deepseek-anthropic');
    expect(chats[0]?.model).toBe('deepseek-flash');

    kernelServer.server.close();
    schedulerServer.server.close();
  });

  it('a plain step releases a stale gate kernel-side instead of leaving it parked', async () => {
    const gate: GateCall[] = [];
    const kernelServer = await listen(fakeKernel(gate));
    const { app } = createServer({
      port: 0, token: 'dev-token',
      haskellHost: '127.0.0.1', haskellPort: kernelServer.port,
    });
    const schedulerServer = await listen(app);
    const base = `http://127.0.0.1:${schedulerServer.port}`;

    const start = await fetch(`${base}/api/session/start`, { method: 'POST', headers: auth, body: JSON.stringify({ mode: 'standard' }) });
    const { sessionId } = (await start.json()) as { sessionId: string };

    await fetch(`${base}/api/agent/step`, {
      method: 'POST', headers: auth,
      body: JSON.stringify({ sessionId, message: 'gated', requireApproval: true }),
    });
    await waitFor(() => gate.some(c => c.kind === 'approval'));

    // The shell never decides; the next plain step supersedes the gate.
    const step = await fetch(`${base}/api/agent/step`, {
      method: 'POST', headers: auth,
      body: JSON.stringify({ sessionId, message: 'just carry on' }),
    });
    expect(step.status).toBe(200);
    // Without this release the kernel would refuse every later step.
    await waitFor(() => gate.some(c => c.kind === 'decision' && c.body.approve === false));

    kernelServer.server.close();
    schedulerServer.server.close();
  });

  it('keeps the shell working when the kernel is unreachable', async () => {
    // Point at a port with nothing on it: the gate must degrade to local-only.
    const { app } = createServer({
      port: 0, token: 'dev-token',
      haskellHost: '127.0.0.1', haskellPort: 1,
    });
    const schedulerServer = await listen(app);
    const base = `http://127.0.0.1:${schedulerServer.port}`;

    const start = await fetch(`${base}/api/session/start`, { method: 'POST', headers: auth, body: JSON.stringify({ mode: 'standard' }) });
    const { sessionId } = (await start.json()) as { sessionId: string };

    const step = await fetch(`${base}/api/agent/step`, {
      method: 'POST', headers: auth,
      body: JSON.stringify({ sessionId, message: 'gate me', requireApproval: true }),
    });
    expect(step.status).toBe(200);
    expect(((await step.json()) as { status?: string }).status).toBe('awaiting_approval');

    const decision = await fetch(`${base}/api/session/${sessionId}/decision`, {
      method: 'POST', headers: auth, body: JSON.stringify({ approve: false }),
    });
    expect(((await decision.json()) as { status?: string }).status).toBe('denied');

    schedulerServer.server.close();
  });
});
