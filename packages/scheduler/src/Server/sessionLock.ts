// Per-session serialization.
//
// A session is a single conversation: two turns running at once interleave
// their messages, which produces exactly the malformed transcript that
// `history-invariants` forbids. The HTTP surface is synchronous, so the honest
// behaviour is to queue the second caller rather than fail it — a double click
// should not lose a message, and it should not run twice in parallel either.
//
// In-process only: two scheduler processes sharing one state directory still
// need an external lock, which is a separate (documented) gap.

const chains = new Map<string, Promise<unknown>>();

/** Run `fn` once the previous turn for this session has settled. */
export function withSessionLock<T>(sessionId: string, fn: () => Promise<T>): Promise<T> {
  const previous = chains.get(sessionId) ?? Promise.resolve();
  // Run regardless of whether the previous turn succeeded: a failed turn must
  // not wedge the session forever.
  const run = previous.then(fn, fn);
  const settled = run.then(() => undefined, () => undefined);
  chains.set(sessionId, settled);
  void settled.then(() => {
    // Drop the entry when nothing else queued behind us.
    if (chains.get(sessionId) === settled) chains.delete(sessionId);
  });
  return run;
}

/** Whether a turn is currently queued or running for this session. */
export function isSessionBusy(sessionId: string): boolean {
  return chains.has(sessionId);
}

/** Test hook: forget all queues (a fresh process has none anyway). */
export function resetSessionLocks(): void {
  chains.clear();
}
