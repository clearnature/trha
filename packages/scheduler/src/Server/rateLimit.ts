/**
 * Sliding-window rate limiter.
 *
 * Fills a gap in the layered model: permissions decide *who* may call a tool,
 * the sandbox decides *where* it runs, but nothing bounded *how often* a
 * metered endpoint can be hit. `/api/balance` and `/api/transcribe` both spend
 * the user's provider quota, so a polling UI or a stray script can turn them
 * into a cost attack — the same class as hammering a provider directly.
 */

export interface RateLimit {
  /** True when this call is allowed; false when it must be refused. */
  (): boolean;
  /** Calls counted in the current window (diagnostics only). */
  readonly used: number;
}

/**
 * @param windowMs window length
 * @param max      allowed calls per window
 * @param now      clock (injectable for tests)
 */
export function rateLimit(
  windowMs: number,
  max: number,
  now: () => number = Date.now,
): RateLimit {
  const hits: number[] = [];

  const allow = (): boolean => {
    const t = now();
    // Drop everything that fell out of the window.
    while (hits.length > 0 && t - hits[0]! >= windowMs) hits.shift();
    if (hits.length >= max) return false;
    hits.push(t);
    return true;
  };

  Object.defineProperty(allow, 'used', { get: () => hits.length });
  return allow as RateLimit;
}
