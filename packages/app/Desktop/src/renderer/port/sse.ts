// SSE helpers for Port.subscribe: consume the scheduler's
// /api/events/:sessionId stream (fetch-based so it can carry the Bearer
// header in the Electron shell; same-origin /studio works tokenless).

import type { PortEvent } from './types.js';

interface RawServerEvent {
  sessionId?: string;
  role?: unknown;
  content?: unknown;
  text?: unknown;
  name?: unknown;
  args?: unknown;
  status?: unknown;
  durationMs?: unknown;
  error?: unknown;
  message?: unknown;
  approve?: unknown;
}

/** Normalise a raw scheduler event payload into a PortEvent (or null). */
export function normalizeEvent(raw: RawServerEvent): PortEvent | null {
  if (raw && (raw.role === 'user' || raw.role === 'assistant') && typeof raw.content === 'string') {
    return { type: 'message', role: raw.role, content: raw.content };
  }
  if (raw && typeof raw.name === 'string' && (raw.status === 'running' || raw.status === 'succeeded' || raw.status === 'failed')) {
    return {
      type: 'tool',
      tool: {
        name: raw.name,
        args: Array.isArray(raw.args) ? raw.args.map(String) : [],
        status: raw.status,
        durationMs: typeof raw.durationMs === 'number' ? raw.durationMs : undefined,
        error: typeof raw.error === 'string' ? raw.error : undefined,
      },
    };
  }
  if (raw && raw.status === 'awaiting_approval' && typeof raw.message === 'string') {
    return { type: 'plan', status: 'awaiting_approval', message: raw.message };
  }
  if (raw && raw.approve !== undefined) {
    return { type: 'decision', status: raw.approve ? 'approved' : 'denied' };
  }
  // Checked last: a delta frame is just { sessionId, text } (A3).
  if (raw && typeof raw.text === 'string') {
    return { type: 'delta', text: raw.text };
  }
  return null;
}

/** Consume a fetch body as an SSE stream and dispatch data frames. */
export async function consumeSse(
  body: ReadableStream<Uint8Array> | null,
  onEvent: (e: PortEvent) => void,
  signal?: AbortSignal,
): Promise<void> {
  if (!body) return;
  const reader = body.getReader();
  const decoder = new TextDecoder();
  let buffer = '';
  try {
    for (;;) {
      if (signal?.aborted) return;
      const { done, value } = await reader.read();
      if (done) return;
      buffer += decoder.decode(value, { stream: true });
      let sep;
      while ((sep = buffer.indexOf('\n\n')) !== -1) {
        const frame = buffer.slice(0, sep);
        buffer = buffer.slice(sep + 2);
        for (const line of frame.split('\n')) {
          if (!line.startsWith('data: ')) continue;
          try {
            const e = normalizeEvent(JSON.parse(line.slice(6)) as RawServerEvent);
            if (e) onEvent(e);
          } catch { /* skip malformed frames */ }
        }
      }
    }
  } finally {
    reader.releaseLock();
  }
}
