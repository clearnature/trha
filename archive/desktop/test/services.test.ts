// The Desktop's stop rules must match `trha stop`: identify by pid file,
// verify the cmdline, and report rather than escalate.

import { describe, expect, it } from 'vitest';
import { looksLikeOurProcess, stopResultText } from '../src/main/services.js';

describe('looksLikeOurProcess', () => {
  it('recognises the scheduler by cli.js', () => {
    expect(looksLikeOurProcess('scheduler', 'node\u0000/x/dist/cli.js\u0000')).toBe(true);
  });

  it('recognises the kernel in serve and stub form', () => {
    expect(looksLikeOurProcess('kernel', '/x/trha\u0000serve\u0000--kernel-port\u000019433')).toBe(true);
    expect(looksLikeOurProcess('kernel', '/x/trha-kernel-stub\u000019433')).toBe(true);
  });

  it('refuses an unrelated process holding a recycled pid', () => {
    expect(looksLikeOurProcess('kernel', 'python3\u0000-m\u0000http.server')).toBe(false);
    expect(looksLikeOurProcess('scheduler', '/usr/bin/vim\u0000notes.md')).toBe(false);
  });

  it('does not confuse the two services', () => {
    expect(looksLikeOurProcess('kernel', 'node\u0000/x/dist/cli.js')).toBe(false);
    expect(looksLikeOurProcess('scheduler', '/x/trha\u0000serve')).toBe(false);
  });
});

describe('stopResultText', () => {
  it('names the service and outcome', () => {
    expect(stopResultText({ service: 'kernel', status: 'not-running' })).toBe('kernel: not running');
    expect(stopResultText({ service: 'scheduler', status: 'stopped', pid: 42 }))
      .toBe('scheduler: stopped (pid 42)');
    expect(stopResultText({ service: 'kernel', status: 'timeout', pid: 7 }))
      .toContain('did not exit within 5s');
    expect(stopResultText({ service: 'kernel', status: 'refused', pid: 7 }))
      .toContain('refused');
  });
});
