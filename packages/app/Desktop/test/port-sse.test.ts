import { describe, expect, it } from 'vitest';
import { consumeSse, normalizeEvent } from '../src/renderer/port/sse.js';
import type { PortEvent } from '../src/renderer/port/types.js';

const rawFrame = (obj: unknown): string => `data: ${JSON.stringify(obj)}\n\n`;

describe('normalizeEvent', () => {
  it('maps agent:message payloads', () => {
    expect(normalizeEvent({ sessionId: 's', role: 'user', content: 'hi' }))
      .toEqual({ type: 'message', role: 'user', content: 'hi' });
  });
  it('maps tool:update payloads', () => {
    expect(normalizeEvent({ name: 'read_file', args: ['a'], status: 'succeeded', durationMs: 3 }))
      .toEqual({ type: 'tool', tool: { name: 'read_file', args: ['a'], status: 'succeeded', durationMs: 3, error: undefined } });
  });
  it('maps plan and decision payloads', () => {
    expect(normalizeEvent({ status: 'awaiting_approval', message: 'm' }))
      .toEqual({ type: 'plan', status: 'awaiting_approval', message: 'm' });
    expect(normalizeEvent({ approve: true })).toEqual({ type: 'decision', status: 'approved' });
    expect(normalizeEvent({ approve: false })).toEqual({ type: 'decision', status: 'denied' });
  });
  it('maps delta payloads — checked after the richer shapes (A3)', () => {
    expect(normalizeEvent({ sessionId: 's', text: 'He' })).toEqual({ type: 'delta', text: 'He' });
    // A message event still wins over the delta rule.
    expect(normalizeEvent({ role: 'assistant', content: 'x', text: 'ignored' }))
      .toEqual({ type: 'message', role: 'assistant', content: 'x' });
  });
  it('returns null for unknown payloads', () => {
    expect(normalizeEvent({})).toBeNull();
    expect(normalizeEvent({ role: 'assistant' })).toBeNull();
  });
});

describe('consumeSse', () => {
  it('dispatches events across chunk boundaries', async () => {
    const frames = rawFrame({ role: 'user', content: 'one' })
      + rawFrame({ name: 'read_file', args: [], status: 'running' })
      + rawFrame({ role: 'assistant', content: 'two' });
    const seen: PortEvent[] = [];
    const chunked = new Blob([frames.slice(0, 17), frames.slice(17)]).stream();
    await consumeSse(chunked, e => seen.push(e));
    expect(seen).toHaveLength(3);
    expect(seen[2]).toMatchObject({ type: 'message', content: 'two' });
  });

  it('stops on abort and skips malformed frames', async () => {
    const seen: PortEvent[] = [];
    const ctrl = new AbortController();
    const stream = new Blob([`data: {bad\n\n${rawFrame({ role: 'assistant', content: 'ok' })}`]).stream();
    ctrl.abort();
    await consumeSse(stream, e => seen.push(e), ctrl.signal);
    expect(seen.length).toBeLessThanOrEqual(1);
  });
});
