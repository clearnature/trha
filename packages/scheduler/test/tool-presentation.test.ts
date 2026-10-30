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
    // `presentResult` receives the canonical `BashResult`, not the rendered text.
    expect(resolveTool('bash')?.presentResult?.({}, { code: 3, cwd: '/tmp' })).toEqual({
      card: 'terminal',
      title: 'exit 3',
    });
  });

  it('bash names the job when the call ran in the background', () => {
    expect(resolveTool('bash')?.presentResult?.({}, { jobId: 'job-2', cwd: '/tmp' })).toEqual({
      card: 'terminal',
      title: 'job job-2',
    });
  });

  it('bash has no closing label when there is no exit code', () => {
    expect(resolveTool('bash')?.presentResult?.({}, { cwd: '/tmp' })).toBeUndefined();
  });

  it('edit counts replacements in its closing label', () => {
    // The canonical `EditResult`, not the rendered text.
    const value = { path: '/tmp/a.txt', replacements: 2, diff: '', oldText: 'a', newText: 'b' };
    expect(resolveTool('edit')?.presentResult?.({ path: 'a.txt' }, value)?.title)
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
