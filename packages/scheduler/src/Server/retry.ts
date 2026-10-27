// Provider-request retry (Reasonix's SessionRetry analogue).
//
// Only transient failures are retried: rate limits, 5xx and timeouts.  A
// connection refusal (kernel not running) is NOT retried — the caller's
// offline fallback should start immediately, not after a 1.5 s backoff.
//
// Retries happen around ONE model request, before any tool runs, so no tool
// side effect can be applied twice.

export const MAX_RETRIES = 2; // 3 attempts total

export function retryDelayMs(attempt: number): number {
  return 500 * 2 ** Math.max(0, attempt);
}

export function isRetryableError(message: string): boolean {
  const m = message.toLowerCase();
  if (m.includes('econnrefused')) return false;
  return (
    m.includes('429') ||
    m.includes('rate limit') ||
    m.includes('too many requests') ||
    m.includes('timeout') ||
    m.includes('timed out') ||
    m.includes('etimedout') ||
    m.includes('econnreset') ||
    m.includes('socket hang up') ||
    /\b(500|502|503|504)\b/.test(m)
  );
}

/**
 * Run `fn`, retrying transient failures with exponential backoff.
 * `onRetry` is notified before each sleep so the shell can render a retry
 * card (`agent:retry`).
 */
export async function withRetry<T>(
  fn: () => Promise<T>,
  onRetry: (attempt: number, delayMs: number, reason: string) => void,
  sleep: (ms: number) => Promise<void> = ms => new Promise(r => setTimeout(r, ms)),
): Promise<T> {
  let attempt = 0;
  for (;;) {
    try {
      return await fn();
    } catch (e) {
      const reason = e instanceof Error ? e.message : String(e);
      if (attempt >= MAX_RETRIES || !isRetryableError(reason)) throw e;
      const delayMs = retryDelayMs(attempt);
      onRetry(attempt + 1, delayMs, reason);
      await sleep(delayMs);
      attempt += 1;
    }
  }
}
