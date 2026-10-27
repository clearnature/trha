// Multi-step plans are kernel-owned; the scheduler forwards.
//
// These tests pin the forwarding contract: the shell's plan routes must reach
// the kernel's routes unchanged, the kernel's status/phase must come back to the
// caller, and a plan decision must not be swallowed by the single-command gate
// (which would answer 400 "No pending approval").

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

interface Call { method: string; path: string; body: unknown }

/** A fake kernel with a tiny plan machine so the forwards have something to say. */
function fakeKernel(calls: Call[]) {
  const kernel = express();
  kernel.use(express.json());
  let phase = 'idle';
  let steps: Array<{ id: string; title: string; status: string }> = [];

  const planJson = () => ({ id: 'p#plan', mode: 'stepwise', steps });
  const pending = () => steps.find(s => s.status === 'pending') ?? null;

  kernel.post('/session/start', (_req, res) => { res.json({ sessionId: 'x', resumed: false }); });
  kernel.post('/session/:id/plan', (req, res) => {
    calls.push({ method: 'POST', path: 'plan', body: req.body });
    const raw = (req.body as { steps?: Array<{ id?: string; title?: string }> }).steps ?? [];
    steps = raw.map((s, i) => ({
      id: s.id ?? `s${i + 1}`, title: s.title ?? '', status: 'pending',
    }));
    phase = 'planning';
    res.json({ status: 'planning', plan: planJson(), pending: pending(), agentState: { state: 'planning' } });
  });
  kernel.get('/session/:id/plan', (_req, res) => {
    calls.push({ method: 'GET', path: 'plan', body: null });
    res.json({ plan: planJson(), agentState: { state: phase } });
  });
  kernel.post('/session/:id/decision', (req, res) => {
    const body = req.body as { action?: string; approve?: boolean; reason?: string };
    calls.push({ method: 'POST', path: 'decision', body });
    if (body.action === 'approve') {
      const step = pending();
      if (!step) return res.status(409).json({ code: 'plan.no_move', error: 'nope' });
      step.status = 'approved';
      phase = `executing_step`;
      return res.json({ status: 'step_approved', plan: planJson(), pending: null, agentState: { state: 'executing_step' } });
    }
    if (body.action === 'reject') {
      phase = 'idle';
      return res.json({ status: 'rejected', plan: planJson(), pending: null, agentState: { state: 'idle' } });
    }
    return res.status(400).json({ code: 'approval.invalid', error: 'bad action' });
  });
  kernel.post('/session/:id/step-result', (req, res) => {
    calls.push({ method: 'POST', path: 'step-result', body: req.body });
    const { stepId, ok } = req.body as { stepId: string; ok: boolean };
    const step = steps.find(s => s.id === stepId && s.status === 'approved');
    if (!step) return res.status(409).json({ code: 'plan.no_step', error: 'no such step out' });
    step.status = ok ? 'done' : 'failed';
    if (!pending()) phase = 'idle'; else phase = 'planning';
    res.json({ status: ok ? 'step_done' : 'step_failed', plan: planJson(), pending: pending(), agentState: { state: phase } });
  });
  kernel.post('/v1/chat/completions', (_req, res) => {
    res.json({ choices: [{ message: { role: 'assistant', content: 'ok', finish_reason: 'stop' } }] });
  });
  return kernel;
}

describe('multi-step plan forwarding', () => {
  it('submits, reads, decides and reports through the scheduler', async () => {
    const calls: Call[] = [];
    const kernelServer = await listen(fakeKernel(calls));
    const { app } = createServer({
      port: 0, token: 'dev-token',
      haskellHost: '127.0.0.1', haskellPort: kernelServer.port,
    });
    const schedulerServer = await listen(app);
    const base = `http://127.0.0.1:${schedulerServer.port}`;

    const start = await fetch(`${base}/api/session/start`, { method: 'POST', headers: auth, body: JSON.stringify({ mode: 'standard' }) });
    const { sessionId } = (await start.json()) as { sessionId: string };

    const submit = await fetch(`${base}/api/session/${sessionId}/plan`, {
      method: 'POST', headers: auth,
      body: JSON.stringify({ mode: 'stepwise', steps: [{ id: 's1', title: 'one' }, { id: 's2', title: 'two' }] }),
    });
    expect(submit.status).toBe(200);
    const submitted = (await submit.json()) as { status?: string; pending?: { id?: string }; mode?: string };
    expect(submitted.status).toBe('planning');
    expect(submitted.pending?.id).toBe('s1');
    expect(submitted.mode).toBe('standard');           // shell field preserved

    const read = await fetch(`${base}/api/session/${sessionId}/plan`, { headers: auth });
    expect(read.status).toBe(200);
    expect(((await read.json()) as { plan?: { id?: string } }).plan?.id).toBe('p#plan');

    // A plan decision must go to the kernel, not be answered by the local gate
    // (which has no pendingApproval and would return 400).
    const approve = await fetch(`${base}/api/session/${sessionId}/decision`, {
      method: 'POST', headers: auth, body: JSON.stringify({ action: 'approve' }),
    });
    expect(approve.status).toBe(200);
    expect(((await approve.json()) as { status?: string }).status).toBe('step_approved');

    const report = await fetch(`${base}/api/session/${sessionId}/step-result`, {
      method: 'POST', headers: auth, body: JSON.stringify({ stepId: 's1', ok: true, output: 'fine' }),
    });
    expect(report.status).toBe(200);
    const reported = (await report.json()) as { status?: string; pending?: { id?: string } };
    expect(reported.status).toBe('step_done');
    expect(reported.pending?.id).toBe('s2');

    // the kernel really saw each call, with the bodies intact
    expect(calls.map(c => `${c.method} ${c.path}`)).toEqual([
      'POST plan', 'GET plan', 'POST decision', 'POST step-result',
    ]);
    expect(calls[1]?.body ?? null).toBe(null);
    const decisionBody = calls[2]?.body as { action?: string } | null | undefined;
    const reportBody = calls[3]?.body as { stepId?: string } | null | undefined;
    expect(decisionBody?.action).toBe('approve');
    expect(reportBody?.stepId).toBe('s1');

    kernelServer.server.close();
    schedulerServer.server.close();
  });

  it('reports kernel refusals instead of pretending success', async () => {
    const calls: Call[] = [];
    const kernelServer = await listen(fakeKernel(calls));
    const { app } = createServer({
      port: 0, token: 'dev-token',
      haskellHost: '127.0.0.1', haskellPort: kernelServer.port,
    });
    const schedulerServer = await listen(app);
    const base = `http://127.0.0.1:${schedulerServer.port}`;

    const start = await fetch(`${base}/api/session/start`, { method: 'POST', headers: auth, body: JSON.stringify({ mode: 'standard' }) });
    const { sessionId } = (await start.json()) as { sessionId: string };

    // reporting a step before anything is approved is refused by the kernel;
    // the scheduler answers 502 (it failed to get an answer), not 200
    const early = await fetch(`${base}/api/session/${sessionId}/step-result`, {
      method: 'POST', headers: auth, body: JSON.stringify({ stepId: 's1', ok: true }),
    });
    expect(early.status).toBe(502);

    const badBody = await fetch(`${base}/api/session/${sessionId}/step-result`, {
      method: 'POST', headers: auth, body: JSON.stringify({ stepId: 's1' }),
    });
    expect(badBody.status).toBe(400);

    const unknown = await fetch(`${base}/api/session/nope/plan`, {
      method: 'POST', headers: auth, body: JSON.stringify({ steps: [] }),
    });
    expect(unknown.status).toBe(404);

    kernelServer.server.close();
    schedulerServer.server.close();
  });

  it('forwards a reject reason to the kernel', async () => {
    const calls: Call[] = [];
    const kernelServer = await listen(fakeKernel(calls));
    const { app } = createServer({
      port: 0, token: 'dev-token',
      haskellHost: '127.0.0.1', haskellPort: kernelServer.port,
    });
    const schedulerServer = await listen(app);
    const base = `http://127.0.0.1:${schedulerServer.port}`;

    const start = await fetch(`${base}/api/session/start`, {
      method: 'POST', headers: auth, body: JSON.stringify({ mode: 'standard' }),
    });
    const { sessionId } = (await start.json()) as { sessionId: string };

    const res = await fetch(`${base}/api/session/${sessionId}/decision`, {
      method: 'POST', headers: auth,
      body: JSON.stringify({ action: 'reject', reason: 'too risky' }),
    });
    expect(res.status).toBe(200);

    const call = calls.find(c => c.path === 'decision');
    const body = (call?.body ?? {}) as { action?: string; reason?: string };
    expect(body.action).toBe('reject');
    expect(body.reason).toBe('too risky');

    kernelServer.server.close();
    schedulerServer.server.close();
  });
});
