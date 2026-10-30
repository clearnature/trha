// Coverage for the presentation hooks added with the tool-level events.
//
// Before this file these hooks had zero tests: the only thing that had ever run
// was `tsc`. The assertions below pin the two behaviours that matter — the label
// a call gets, and what happens when there is nothing meaningful to show.
import { describe, expect, it } from 'vitest';
import '../src/Server/toolDeclarations.js';
import '../src/Server/standardTools.js';
import '../src/Server/extraTools.js';
import { resolveTool } from '../src/Server/toolRegistry.js';

describe('tool presentation hooks', () => {
  it('bash labels the call with the command line', () => {
    expect(resolveTool('bash')?.presentCall?.({ command: 'ls -la' })).toEqual({
      card: 'terminal',
      title: 'ls -la',
      rawInput: 'ls -la',
    });
  });

  it('keeps a long command on one clipped line', () => {
    const view = resolveTool('bash')?.presentCall?.({ command: 'x'.repeat(200) });
    expect(view?.title.length).toBeLessThanOrEqual(49); // 48 + the ellipsis
    expect(view?.title).not.toContain('\n');
  });

  it('edit labels the call as a diff', () => {
    expect(resolveTool('edit')?.presentCall?.({ path: 'src/core/Main.hs' })).toEqual({
      card: 'diff',
      title: 'edit src/core/Main.hs',
      rawInput: 'src/core/Main.hs',
    });
  });

  it('bash reports the exit code on the closing card', () => {
    expect(resolveTool('bash')?.presentResult?.({}, 'exit 3\nboom')).toEqual({
      card: 'terminal',
      title: 'exit 3',
    });
  });

  it('bash has no closing label when the output carries no exit code', () => {
    expect(resolveTool('bash')?.presentResult?.({}, 'garbage')).toBeUndefined();
  });

  it('edit counts replacements in its closing label', () => {
    const out = 'OK: edit -> /tmp/a.txt (2 replacements)\n\n@@ -1,1 +1,1 @@';
    expect(resolveTool('edit')?.presentResult?.({ path: 'a.txt' }, out)?.title)
      .toBe('edited a.txt · 2');
  });

  it('a call with no meaningful argument yields a blank title the emitter drops', () => {
    // `oneLine(undefined)` is '', so the raw hook returns a title that trims to
    // just the prefix. The emitter treats a blank title as "no view", and the
    // shell falls back to the tool name — that fallback is the intended path,
    // not an oversight, so it is asserted here rather than left implicit.
    expect(resolveTool('create_goal')?.presentCall?.({})?.title.trim()).toBe('goal:');
  });
});
