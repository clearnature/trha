// Environment parsing: "unset" must not mean zero.
//
// `Number(process.env.X ?? '')` is 0, which silently disabled subagents and the
// schedule driver whenever the variable was not set. These cases pin the rule
// for every knob that matters.

import { describe, it, expect, afterEach } from 'vitest';
import { envCap, envInt } from '../src/Server/env.js';

const touched = new Set<string>();
function setEnv(name: string, value: string | undefined): void {
  touched.add(name);
  if (value === undefined) delete process.env[name];
  else process.env[name] = value;
}

afterEach(() => {
  for (const n of touched) delete process.env[n];
  touched.clear();
});

describe('envInt', () => {
  it('uses the default when unset or empty', () => {
    setEnv('TRHA_X_INT', undefined);
    expect(envInt('TRHA_X_INT', 2, { allowZero: true })).toBe(2);
    setEnv('TRHA_X_INT', '');
    expect(envInt('TRHA_X_INT', 2, { allowZero: true })).toBe(2);
    setEnv('TRHA_X_INT', '   ');
    expect(envInt('TRHA_X_INT', 2, { allowZero: true })).toBe(2);
  });

  it('parses a real value', () => {
    setEnv('TRHA_X_INT', '7');
    expect(envInt('TRHA_X_INT', 2)).toBe(7);
  });

  it('accepts 0 only when the knob allows it', () => {
    setEnv('TRHA_X_INT', '0');
    expect(envInt('TRHA_X_INT', 5000, { allowZero: true })).toBe(0);
    expect(envInt('TRHA_X_INT', 5000)).toBe(5000);       // 0 would mean "off" by accident
    expect(envInt('TRHA_X_INT', 300_000, { min: 1 })).toBe(300_000);
  });

  it('falls back on garbage and negatives', () => {
    setEnv('TRHA_X_INT', 'abc');
    expect(envInt('TRHA_X_INT', 2)).toBe(2);
    setEnv('TRHA_X_INT', '-3');
    expect(envInt('TRHA_X_INT', 2)).toBe(2);
    setEnv('TRHA_X_INT', '2.5');
    expect(envInt('TRHA_X_INT', 2)).toBe(2.5);           // finite numbers pass
  });

  it('the two knobs that used to be disabled default to working values', () => {
    setEnv('TRHA_MAX_SUBAGENT_DEPTH', undefined);
    setEnv('TRHA_SCHEDULE_TICK_MS', undefined);
    expect(envInt('TRHA_MAX_SUBAGENT_DEPTH', 2, { allowZero: true })).toBe(2);
    expect(envInt('TRHA_SCHEDULE_TICK_MS', 5000, { allowZero: true })).toBe(5000);
  });
});

describe('envCap', () => {
  it('means "no cap" when unset or zero', () => {
    setEnv('TRHA_X_CAP', undefined);
    expect(envCap('TRHA_X_CAP')).toBe(Number.POSITIVE_INFINITY);
    setEnv('TRHA_X_CAP', '0');
    expect(envCap('TRHA_X_CAP')).toBe(Number.POSITIVE_INFINITY);
  });

  it('returns a real cap when asked', () => {
    setEnv('TRHA_X_CAP', '12');
    expect(envCap('TRHA_X_CAP')).toBe(12);
  });
});
