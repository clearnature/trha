// Single source of truth for the events forwarded over
// `GET /api/events/:sessionId` (P-11, 2026-10-27).
//
// The SSE route used to list `events.on('...')` / `events.off('...')` twice
// (subscribe and unsubscribe); those two lists could drift.  The route now
// iterates this array, so adding an event is a one-line change here.
//
// Note: these are *transport* event names (what the scheduler pushes), not
// the kernel's `SessionEvent` kinds in `Core/Types.ts`.

export const SSE_EVENTS = [
  'agent:message',
  'agent:delta',
  'agent:reasoning',
  'agent:retry',
  'agent:model-request',
  'agent:context',
  'agent:plan',
  'agent:decision',
  'tool:update',
] as const;

export type SseEvent = typeof SSE_EVENTS[number];
