// Session permission posture (Reasonix Studio parity,
// internal/frontend/tui/posture.go): Shift+Tab cycles
// read-only → ask → auto → YOLO → plan; Ctrl+Y toggles YOLO.

import { describe, it, expect } from 'vitest';
import express from 'express';
import type { Server } from 'http';
import type { AddressInfo } from 'net';
import { createServer } from '../src/Server/index.js';
import {
  applyPermissionMode, modeLabel, nextMode, toggleYolo,
  type PermissionMode,
} from '../src/Permission/modes.js';

describe('permission mode helpers', () => {
  it('cycles through the five postures', () => {
    const seen: PermissionMode[] = [];
    let mode: PermissionMode = 'read-only';
    for (let i = 0; i < 5; i++) {
      seen.push(mode);
      mode = nextMode(mode);
    }
    expect(seen).toEqual(['read-only', 'ask', 'auto', 'yolo', 'plan']);
    expect(mode).toBe('read-only');
  });

  it('labels each posture', () => {
    expect(['read-only', 'ask', 'auto', 'yolo', 'plan'].map(m => modeLabel(m as PermissionMode)))
      .toEqual(['Read only', 'Ask', 'Auto', 'YOLO', 'Plan']);
  });

  it('toggles YOLO and restores the previous posture', () => {
    expect(toggleYolo('auto', null)).toEqual({ mode: 'yolo', restore: 'auto' });
    expect(toggleYolo('yolo', 'auto')).toEqual({ mode: 'auto', restore: null });
    // Studio falls back to ask, not read-only.
    expect(toggleYolo('yolo', null)).toEqual({ mode: 'ask', restore: null });
    // Ctrl+Y inside Plan: stay in plan, remember read-only for the way back.
    expect(toggleYolo('plan', null)).toEqual({ mode: 'yolo', restore: 'read-only' });
  });

  it('lets an explicit deny win in every mode', () => {
    const deny = { action: 'deny' as const, reason: 'denied by rule' };
    for (const mode of ['read-only', 'ask', 'auto', 'yolo', 'plan'] as PermissionMode[]) {
      expect(applyPermissionMode(mode, 'write', deny)).toEqual(deny);
    }
  });

  it('read-only / plan allow observation and refuse writes', () => {
    for (const mode of ['read-only', 'plan'] as PermissionMode[]) {
      expect(applyPermissionMode(mode, 'read', { action: 'allow' }).action).toBe('allow');
      expect(applyPermissionMode(mode, 'grep', { action: 'allow' }).action).toBe('allow');
      const write = applyPermissionMode(mode, 'write', { action: 'allow' });
      expect(write.action).toBe('deny');
      if (write.action === 'deny') expect(write.reason).toContain(`${mode} mode`);
      expect(applyPermissionMode(mode, 'bash', { action: 'allow' }).action).toBe('deny');
    }
  });

  it('ask requires confirmation for mutating tools only', () => {
    expect(applyPermissionMode('ask', 'read', { action: 'allow' }).action).toBe('allow');
    expect(applyPermissionMode('ask', 'write', { action: 'allow' }).action).toBe('ask');
  });

  it('auto keeps the rule verdict; YOLO skips ask rules', () => {
    expect(applyPermissionMode('auto', 'write', { action: 'ask', reason: 'r' }).action).toBe('ask');
    expect(applyPermissionMode('yolo', 'write', { action: 'ask', reason: 'r' }).action).toBe('allow');
    expect(applyPermissionMode('yolo', 'write', { action: 'deny', reason: 'r' }).action).toBe('deny');
  });
});

const auth = { 'Content-Type': 'application/json', Authorization: 'Bearer dev-token' } as Record<string, string>;

async function listen(app: express.Express): Promise<{ port: number; server: Server }> {
  const s = await new Promise<Server>(resolve => {
    const srv = app.listen(0, '127.0.0.1', () => resolve(srv));
  });
  return { port: (s.address() as AddressInfo).port, server: s };
}

describe('session mode endpoint', () => {
  it('cycles via Shift+Tab and toggles YOLO via Ctrl+Y', async () => {
    const { app } = createServer({ port: 0, token: 'dev-token' });
    const { port, server } = await listen(app);
    const base = `http://127.0.0.1:${port}`;
    const start = await fetch(`${base}/api/session/start`, {
      method: 'POST', headers: auth, body: JSON.stringify({ mode: 'standard' }),
    });
    const { sessionId } = (await start.json()) as { sessionId: string };
    const modeUrl = `${base}/api/session/${sessionId}/mode`;

    expect(await (await fetch(modeUrl, { headers: auth })).json()).toMatchObject({
      mode: 'read-only', planMode: false, label: 'Read only',
    });

    const post = async (body: unknown) =>
      (await (await fetch(modeUrl, { method: 'POST', headers: auth, body: JSON.stringify(body) })).json()) as {
        mode: PermissionMode; planMode: boolean; label: string; yoloRestore: string | null;
      };

    // From the default read-only: ask → auto → yolo → plan(ask) → read-only.
    const seen: Array<[string, boolean]> = [];
    for (let i = 0; i < 5; i++) {
      const state = await post({ action: 'cycle' });
      seen.push([state.mode, state.planMode]);
    }
    expect(seen).toEqual([
      ['ask', false], ['auto', false], ['yolo', false], ['ask', true], ['read-only', false],
    ]);

    // Ctrl+Y from read-only → yolo, second press → read-only.
    expect(await post({ action: 'yolo' })).toMatchObject({ mode: 'yolo', yoloRestore: 'read-only' });
    expect(await post({ action: 'yolo' })).toMatchObject({ mode: 'read-only', yoloRestore: null });

    // Plan + Ctrl+Y keeps planMode.
    await post({ action: 'set', mode: 'plan' });
    const yoloInPlan = await post({ action: 'yolo' });
    expect(yoloInPlan).toMatchObject({ mode: 'yolo', planMode: true });

    server.close();
  });
});
