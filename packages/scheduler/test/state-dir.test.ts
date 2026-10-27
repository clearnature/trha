// Session persistence default: without TRHA_STATE_DIR a scheduler started by
// hand must still persist, so the standard ~/.trha/scheduler-state is used
// instead of silently running in memory only.

import { describe, expect, it, afterEach } from 'vitest';
import { defaultStateDir } from '../src/Server/stateStore.js';

const saved = process.env.TRHA_STATE_DIR;

afterEach(() => {
  if (saved === undefined) delete process.env.TRHA_STATE_DIR;
  else process.env.TRHA_STATE_DIR = saved;
});

describe('defaultStateDir', () => {
  it('falls back to ~/.trha/scheduler-state', () => {
    delete process.env.TRHA_STATE_DIR;
    expect(defaultStateDir()).toMatch(/\.trha[/\\]scheduler-state$/);
  });

  it('honours TRHA_STATE_DIR', () => {
    process.env.TRHA_STATE_DIR = '/tmp/trha-state';
    expect(defaultStateDir()).toBe('/tmp/trha-state');
  });

  it('ignores a blank override', () => {
    process.env.TRHA_STATE_DIR = '   ';
    expect(defaultStateDir()).toMatch(/\.trha[/\\]scheduler-state$/);
  });
});
