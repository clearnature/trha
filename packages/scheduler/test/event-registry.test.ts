import { describe, expect, it } from 'vitest';
import { SSE_EVENTS } from '../src/Core/EventRegistry.js';

describe('SSE event registry (P-11)', () => {
  it('is non-empty and has no duplicates', () => {
    expect(SSE_EVENTS.length).toBeGreaterThan(0);
    expect(new Set(SSE_EVENTS).size).toBe(SSE_EVENTS.length);
  });

  it('contains the events the shells rely on', () => {
    expect(SSE_EVENTS).toContain('agent:message');
    expect(SSE_EVENTS).toContain('agent:delta');
    expect(SSE_EVENTS).toContain('agent:plan');
    expect(SSE_EVENTS).toContain('agent:decision');
    expect(SSE_EVENTS).toContain('tool:update');
  });
});
