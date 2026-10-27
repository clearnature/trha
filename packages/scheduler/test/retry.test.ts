// Transient provider failures are retried with backoff; a refused connection
// is not (the offline fallback should start immediately).

import { describe, it, expect } from 'vitest';
import { MAX_RETRIES, isRetryableError, retryDelayMs, withRetry } from '../src/Server/retry.js';

describe('isRetryableError', () => {
  it('retries rate limits, 5xx and timeouts', () => {
    expect(isRetryableError('429 Too Many Requests')).toBe(true);
    expect(isRetryableError('rate limit exceeded')).toBe(true);
    expect(isRetryableError('kernel stream failed: HTTP 503')).toBe(true);
    expect(isRetryableError('stream timed out after 20s')).toBe(true);
    expect(isRetryableError('read ECONNRESET')).toBe(true);
  });

  it('does not retry a refused connection or a user error', () => {
    expect(isRetryableError('connect ECONNREFUSED 127.0.0.1:3456')).toBe(false);
    expect(isRetryableError('400 invalid api key')).toBe(false);
    expect(isRetryableError('provider.adapter_unavailable')).toBe(false);
  });
});

describe('retryDelayMs', () => {
  it('backs off exponentially', () => {
    expect(retryDelayMs(0)).toBe(500);
    expect(retryDelayMs(1)).toBe(1000);
  });
});

describe('withRetry', () => {
  it('returns the first successful result', async () => {
    const attempts: number[] = [];
    const out = await withRetry(async () => { attempts.push(1); return 'ok'; }, () => {}, async () => {});
    expect(out).toBe('ok');
    expect(attempts).toHaveLength(1);
  });

  it('retries a transient failure and reports each backoff', async () => {
    let calls = 0;
    const notices: Array<[number, number, string]> = [];
    const out = await withRetry(
      async () => {
        calls += 1;
        if (calls < 3) throw new Error('429 Too Many Requests');
        return 'recovered';
      },
      (attempt, delay, reason) => notices.push([attempt, delay, reason]),
      async () => {},
    );
    expect(out).toBe('recovered');
    expect(calls).toBe(3);
    expect(notices.map(n => n[0])).toEqual([1, 2]);
    expect(notices.map(n => n[1])).toEqual([500, 1000]);
  });

  it('gives up after the retry budget', async () => {
    let calls = 0;
    await expect(withRetry(
      async () => { calls += 1; throw new Error('503 unavailable'); },
      () => {},
      async () => {},
    )).rejects.toThrow('503');
    expect(calls).toBe(MAX_RETRIES + 1);
  });

  it('does not retry a non-transient failure', async () => {
    let calls = 0;
    await expect(withRetry(
      async () => { calls += 1; throw new Error('ECONNREFUSED'); },
      () => {},
      async () => {},
    )).rejects.toThrow('ECONNREFUSED');
    expect(calls).toBe(1);
  });
});
