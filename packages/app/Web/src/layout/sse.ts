// SSE payload classification for /api/events/:sessionId.
//
// The scheduler interleaves several shapes on one stream and sends them as
// bare `data:` payloads (no `event:` line). The rules mirror the CLI's
// Core/SSE.hs: tool progress first (name + status), then reasoning, text
// deltas, step/compaction/retry notices, message echoes, and the plan gate.

export interface ToolEvent {
  name: string;
  args?: string[];
  status: 'running' | 'succeeded' | 'failed';
  error?: string;
  durationMs?: number;
  output?: string;
}

export type SseEvent =
  | { kind: 'tool'; tool: ToolEvent }
  | { kind: 'reasoning'; text: string }
  | { kind: 'text' }
  | { kind: 'message'; role: string }
  | { kind: 'step'; round: number; messageCount: number; toolCount: number }
  | { kind: 'compaction'; trigger: string; savedTokens: number }
  | { kind: 'retry'; attempt: number; delayMs: number; reason: string }
  | { kind: 'plan' }
  | { kind: 'unknown'; raw: string };

function isToolEvent(value: unknown): value is ToolEvent {
  if (typeof value !== 'object' || value === null) return false;
  const v = value as Record<string, unknown>;
  return typeof v.name === 'string'
    && (v.status === 'running' || v.status === 'succeeded' || v.status === 'failed');
}

export function parseSsePayload(raw: string): SseEvent {
  let value: unknown;
  try {
    value = JSON.parse(raw);
  } catch {
    return { kind: 'unknown', raw };
  }
  if (typeof value !== 'object' || value === null) return { kind: 'unknown', raw };
  const v = value as Record<string, unknown>;

  if (isToolEvent(v)) {
    const tool: ToolEvent = {
      name: v.name as string,
      status: v.status as ToolEvent['status'],
    };
    if (Array.isArray(v.args)) tool.args = v.args as string[];
    if (typeof v.error === 'string') tool.error = v.error;
    if (typeof v.durationMs === 'number') tool.durationMs = v.durationMs;
    if (typeof v.output === 'string') tool.output = v.output;
    return { kind: 'tool', tool };
  }
  if (typeof v.reasoning === 'string') return { kind: 'reasoning', text: v.reasoning };
  if (typeof v.text === 'string') return { kind: 'text' };
  if (typeof v.trigger === 'string' && typeof v.savedTokens === 'number') {
    return { kind: 'compaction', trigger: v.trigger, savedTokens: v.savedTokens };
  }
  if (typeof v.attempt === 'number' && typeof v.delayMs === 'number') {
    return { kind: 'retry', attempt: v.attempt, delayMs: v.delayMs, reason: String(v.reason ?? '') };
  }
  if (typeof v.round === 'number') {
    return {
      kind: 'step',
      round: v.round,
      messageCount: Number(v.messageCount ?? 0),
      toolCount: Number(v.toolCount ?? 0),
    };
  }
  if (typeof v.role === 'string') return { kind: 'message', role: v.role };
  if (typeof v.status === 'string' && typeof v.message === 'string') return { kind: 'plan' };
  return { kind: 'unknown', raw };
}

/** Fold a tool update into the card list: a running card is replaced by its
 * terminal update when name and args match; everything else appends. */
export function mergeToolEvents(list: ToolEvent[], next: ToolEvent): ToolEvent[] {
  const key = (e: ToolEvent) => e.name + '\u0000' + JSON.stringify(e.args ?? []);
  for (let i = list.length - 1; i >= 0; i -= 1) {
    const prev = list[i];
    if (prev === undefined) continue;
    if (prev.status === 'running' && key(prev) === key(next)) {
      const copy = list.slice();
      copy[i] = next;
      return copy;
    }
    if (prev.status !== 'running') break;
  }
  return [...list, next];
}
