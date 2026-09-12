import { describe, expect, it } from 'vitest';
import { MockPort } from '../src/renderer/port/mock.js';
import type { Port } from '../src/renderer/port/port.js';
import type { PortEvent } from '../src/renderer/port/types.js';

// The mock is also the compile-time consumer proof of the Port interface.
const port: Port = new MockPort();

describe('MockPort', () => {
  it('lists two fixture sessions and returns their messages', async () => {
    const sessions = await port.listSessions();
    expect(sessions.map(s => s.id)).toEqual(['mock-1', 'mock-2']);
    const msgs = await port.sessionMessages('mock-1');
    expect(msgs[0]).toMatchObject({ role: 'user', content: 'hello from the mock fixture' });
  });

  it('createSession adds a session and getSession round-trips', async () => {
    const { sessionId, mode } = await port.createSession('minimal');
    const s = await port.getSession(sessionId);
    expect(s.mode).toBe('minimal');
    expect(s.messages).toEqual([]);
  });

  it('step appends user+assistant and returns the reply', async () => {
    const before = (await port.getSession('mock-2')).messages.length;
    const out = await port.step('mock-2', 'hi');
    if (out.status === 'awaiting_approval') throw new Error('unexpected plan');
    expect(out.reply).toContain('hi');
    expect((await port.getSession('mock-2')).messages).toHaveLength(before + 2);
  });

  it('step with requireApproval returns PlanAwaiting and sets pending', async () => {
    const out = await port.step('mock-2', 'plan me', true);
    expect(out.status).toBe('awaiting_approval');
    const s = await port.getSession('mock-2');
    expect(s.pendingApproval?.message).toBe('plan me');
  });

  it('decision approves and appends a reply', async () => {
    const out = await port.decision('mock-2', true);
    if (out.status !== 'approved') throw new Error('expected approved');
    expect(out.reply).toContain('approved');
  });

  it('decision deny returns denied without a reply', async () => {
    const out = await port.decision('mock-2', false);
    expect(out.status).toBe('denied');
  });

  it('subscribe receives step events and unsubscribes cleanly', async () => {
    const seen: PortEvent[] = [];
    const off = port.subscribe('mock-2', e => seen.push(e));
    await port.step('mock-2', 'stream this');
    expect(seen.some(e => e.type === 'message' && e.role === 'user')).toBe(true);
    expect(seen.some(e => e.type === 'message' && e.role === 'assistant')).toBe(true);
    off();
    const after: PortEvent[] = [];
    port.subscribe('mock-2', e => after.push(e));
    await port.step('mock-2', 'again');
    expect(after.length).toBe(2);
  });

  it('exposes a synthetic emitMock for manual event push', async () => {
    const seen: PortEvent[] = [];
    const off = (port as MockPort).subscribe('mock-2', e => seen.push(e));
    (port as MockPort).emitMock('mock-2', { type: 'tool', tool: { name: 'read_file', args: ['a'], status: 'succeeded', durationMs: 2 } });
    expect(seen[0]).toMatchObject({ type: 'tool' });
    off();
  });

  it('reports a mock studio version', async () => {
    const v = await port.studioVersion();
    expect(v.current).toBe('0.0.0-mock');
  });

  it('deleteSession removes the session', async () => {
    const { sessionId } = await port.createSession('standard');
    await port.deleteSession(sessionId);
    await expect(port.getSession(sessionId)).rejects.toThrow(/not found/);
  });
});
