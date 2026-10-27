// Session truth projection (P-04): rebuild the model-visible message sequence
// from the kernel event log.
//
// Mirrors `src/core/Core/Session/Projection.hs` — both use the same rules and
// the same fixture in `test/session-truth.test.ts`.  This is the scheduler half
// of `docs/contracts/session-truth.md`: A-class history (what the model saw)
// has one authority (the kernel log); the scheduler's persisted `messages`
// must be derivable from it.

export interface KernelEvent {
  kind: string;
  text?: string;
  tool?: string;
  payload?: unknown;
  agentState?: unknown;
  approve?: boolean;
}

export interface SessionMessage {
  role: 'user' | 'assistant' | 'system' | 'tool';
  content: string;
  tool_calls?: { name: string; arguments: unknown }[];
  name?: string;
}

/** Pure projection.  State/approval/plan events are not messages. */
export function messagesFromEvents(events: KernelEvent[]): SessionMessage[] {
  const out: SessionMessage[] = [];
  for (const e of events) {
    switch (e.kind) {
      case 'user_message':
        out.push({ role: 'user', content: e.text ?? '' });
        break;
      case 'assistant_message':
        out.push({ role: 'assistant', content: e.text ?? '' });
        break;
      case 'system':
        out.push({ role: 'system', content: e.text ?? '' });
        break;
      case 'tool_call':
        out.push({
          role: 'assistant',
          content: '',
          tool_calls: [{ name: e.tool ?? '', arguments: e.payload }],
        });
        break;
      case 'tool_result':
        out.push({
          role: 'tool',
          content: JSON.stringify(e.payload),
          ...(e.tool ? { name: e.tool } : {}),
        });
        break;
      default:
        // agent_state / approval_requested / approval_decided / plan_changed
        break;
    }
  }
  return out;
}
