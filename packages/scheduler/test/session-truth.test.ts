// Contract test for docs/contracts/session-truth.md (P-04).
//
// Mirrors `src/core/Core/Session/Projection.hs`: the same fixture must produce
// the same message sequence on both sides.  The Haskell half is
// `test/SessionTruthSpec.hs`.

import { describe, expect, it } from 'vitest';
import { messagesFromEvents, type KernelEvent } from '../src/Core/SessionTruth.js';

const events: KernelEvent[] = [
  { kind: 'user_message', text: 'hello' },
  { kind: 'assistant_message', text: 'hi' },
  { kind: 'tool_call', tool: 'bash', payload: { cmd: 'ls' } },
  { kind: 'tool_result', tool: 'bash', payload: { out: 'a' } },
  { kind: 'agent_state', agentState: 'Processing' },
];

const expected = [
  { role: 'user', content: 'hello' },
  { role: 'assistant', content: 'hi' },
  { role: 'assistant', content: '', tool_calls: [{ name: 'bash', arguments: { cmd: 'ls' } }] },
  { role: 'tool', content: '{"out":"a"}', name: 'bash' },
];

describe('Session truth (kernel log -> messages)', () => {
  it('rebuilds user / assistant / tool messages in order', () => {
    expect(messagesFromEvents(events)).toEqual(expected);
  });

  it('matches the persisted scheduler message fixture (same sequence)', () => {
    const persisted = {
      v: 2,
      sessionId: 'session-1',
      mode: 'standard',
      messages: expected,
      pendingApproval: null,
      createdAt: '2026-10-27T00:00:00.000Z',
      updatedAt: '2026-10-27T00:00:00.000Z',
    };
    expect(messagesFromEvents(events)).toEqual(persisted.messages);
  });

  it('skips state/approval/plan events (not messages)', () => {
    const withState: KernelEvent[] = [
      { kind: 'user_message', text: 'hi' },
      { kind: 'agent_state', agentState: 'Idle' },
      { kind: 'approval_decided', approve: true },
      { kind: 'plan_changed' },
    ];
    expect(messagesFromEvents(withState)).toEqual([{ role: 'user', content: 'hi' }]);
  });
});
