// Plugin directory watcher: plan builder + reconciliation order.

import { describe, expect, it } from 'vitest';
import { computePlan, FileState, ReconcilePlan } from '../src/Plugins/watcher.js';

const st = (mtimeMs: number, pluginName?: string): FileState => ({ mtimeMs, pluginName });

describe('computePlan', () => {
  it('adds new files, removes vanished ones, reloads changed ones', () => {
    const known = new Map<string, FileState>([
      ['a.js', st(100, 'pa')],
      ['gone.js', st(100, 'pg')],
    ]);
    const seen = new Map<string, FileState>([
      ['a.js', st(100)],
      ['b.js', st(200)],
    ]);
    const plan = computePlan(known, seen);
    expect(plan).toEqual({ added: ['b.js'], removed: ['pg'], changed: [] } satisfies ReconcilePlan);
  });

  it('flags changed files by mtime', () => {
    const known = new Map<string, FileState>([['p.js', st(100, 'pp')]]);
    const seen = new Map<string, FileState>([['p.js', st(250)]]);
    const plan = computePlan(known, seen);
    expect(plan.changed).toEqual(['p.js']);
    expect(plan.removed).toEqual([]);
  });

  it('produces an empty plan when nothing changed', () => {
    const known = new Map<string, FileState>([['p.js', st(100, 'pp')]]);
    const seen = new Map<string, FileState>([['p.js', st(100)]]);
    expect(computePlan(known, seen)).toEqual({ added: [], removed: [], changed: [] });
  });
});
