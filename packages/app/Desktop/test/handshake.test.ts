import { describe, expect, it } from 'vitest';
import { Handshake, isSupported, parseHandshake } from '../src/main/handshake.js';

describe('parseHandshake', () => {
  it('parses a valid handshake line', () => {
    expect(parseHandshake('{"v":1,"name":"trha-scheduler","port":3456}'))
      .toEqual({ v: 1, name: 'trha-scheduler', port: 3456 } satisfies Handshake);
  });

  it('tolerates surrounding whitespace and a trailing newline', () => {
    expect(parseHandshake('  {"v":1,"name":"trha-scheduler","port":1}\n').v).toBe(1);
  });

  it('returns null for non-object output (log lines must not be handshakes)', () => {
    expect(parseHandshake('Scheduler listening on port 3456')).toBeNull();
  });

  it('returns null for malformed JSON', () => {
    expect(parseHandshake('{oops')).toBeNull();
  });

  it('returns null when required fields are missing', () => {
    expect(parseHandshake('{"v":1}')).toBeNull();
    expect(parseHandshake('{"v":1,"name":"x"}')).toBeNull();
  });
});

describe('isSupported', () => {
  it('accepts v1 of the trha scheduler', () => {
    expect(isSupported({ v: 1, name: 'trha-scheduler', port: 1 })).toBe(true);
  });
  it('rejects unknown versions', () => {
    expect(isSupported({ v: 2, name: 'trha-scheduler', port: 1 })).toBe(false);
  });
  it('rejects a different child name', () => {
    expect(isSupported({ v: 1, name: 'other-daemon', port: 1 })).toBe(false);
  });
});
