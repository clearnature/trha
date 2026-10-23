// Context governance: thresholds, what each pass does, and — the point of the
// whole exercise — that a pass produces a *stable* new prefix instead of
// rewriting on every turn.

import { describe, it, expect } from 'vitest';
import {
  DEFAULT_GOVERNANCE, estimateMessages, estimateTokens, govern,
  type GovernedMessage,
} from '../src/Server/contextGovernor.js';

const sys = (text: string): GovernedMessage => ({ role: 'system', content: text });

/** A conversation of `turns` user/assistant pairs, each `chars` wide. */
function conversation(turns: number, chars: number): GovernedMessage[] {
  const body = 'x'.repeat(chars);
  const out: GovernedMessage[] = [sys('stable system prompt')];
  for (let i = 0; i < turns; i++) {
    out.push({ role: 'user', content: `turn ${i}: ${body}` });
    out.push({ role: 'assistant', content: `reply ${i}: ${body}` });
  }
  return out;
}

const SMALL = { ...DEFAULT_GOVERNANCE, window: 10_000, tailRatio: 0.1, minFoldTokens: 50 };

describe('contextGovernor', () => {
  it('does nothing below the snip threshold', () => {
    const msgs = conversation(3, 100);
    const r = govern(msgs, 0, SMALL);
    expect(r.trigger).toBe('none');
    expect(r.prefixChanged).toBe(false);
    expect(r.messages).toEqual(msgs);
  });

  it('snips old tool results before anything heavier', () => {
    const big = 'y'.repeat(2000);
    const msgs: GovernedMessage[] = [
      { role: 'system', content: 'sys' },
      { role: 'user', content: 'do it' },
      { role: 'tool', tool_call_id: 'c1', content: big },
      { role: 'assistant', content: 'done' },
      ...conversation(8, 800).slice(1),
    ];
    // 6000/10000 = 60% → snip band; keep the last 20% verbatim
    const r = govern(msgs, 6000, SMALL);
    expect(r.trigger).toBe('snip');
    expect(r.prefixChanged).toBe(true);
    expect(r.messages[0]).toEqual(msgs[0]);
    // the old tool result was elided to a fixed placeholder ...
    const tool = r.messages.find(m => m.role === 'tool');
    expect(tool?.content).toMatch(/^\[tool result elided: \d+ chars\]$/);
    // ... and message count is unchanged (snip edits in place)
    expect(r.messages.length).toBe(msgs.length);
  });

  it('folds above the fold threshold, keeping a verbatim tail', () => {
    const msgs = conversation(10, 800);
    const r = govern(msgs, 8500, SMALL);       // 85% → fold
    expect(r.trigger).toBe('fold');
    // the system prompt and the opening user turn survive, then the marker
    expect(r.messages[0]).toEqual(msgs[0]);
    expect(r.messages[1]).toEqual(msgs[1]);
    expect(r.messages[2]?.content).toMatch(/^\[context folded: \d+ earlier messages/);
    // the tail survives verbatim
    expect(r.messages.at(-1)).toEqual(msgs.at(-1));
    expect(r.messages.length).toBeLessThan(msgs.length);
    expect(r.savedTokens).toBeGreaterThan(0);
  });

  it('forces a compaction at the force threshold', () => {
    const msgs = conversation(10, 800);
    const r = govern(msgs, 9500, SMALL);
    expect(r.trigger).toBe('force');
    expect(r.messages[0]).toEqual(msgs[0]);
    expect(r.messages[1]).toEqual(msgs[1]);
    expect(r.messages[2]?.content).toMatch(/^\[context compacted:/);
  });

  it('produces a byte-identical result for the same input (prefix stability)', () => {
    const msgs = conversation(10, 800);
    const a = govern(msgs, 8500, SMALL);
    const b = govern(msgs, 8500, SMALL);
    expect(a.messages).toEqual(b.messages);
    // and the marker carries no timestamp or random id
    const marker = a.messages.find(m => m.content.startsWith('[context'));
    expect(marker?.content ?? '').not.toMatch(/\d{4}-\d{2}-\d{2}|[0-9a-f]{8}-/);
  });

  it('is a no-op once compacted history is back under threshold', () => {
    const msgs = conversation(10, 800);
    const folded = govern(msgs, 8500, SMALL);
    const again = govern(folded.messages, estimateMessages(folded.messages), SMALL);
    expect(again.trigger).toBe('none');
    expect(again.prefixChanged).toBe(false);
  });

  it('skips a fold that saves less than the economics floor', () => {
    const msgs = conversation(3, 60);
    const r = govern(msgs, 8100, { ...SMALL, minFoldTokens: 100_000 });
    expect(r.trigger).toBe('none');
    expect(r.prefixChanged).toBe(false);
  });

  it('uses the provider count over its own estimate', () => {
    const msgs = conversation(10, 800);         // enough content to elide
    const r = govern(msgs, 9500, SMALL);        // provider says 95%
    expect(r.trigger).toBe('force');
  });

  it('estimates CJK heavier than ASCII', () => {
    expect(estimateTokens('你好世界')).toBeGreaterThan(estimateTokens('abcd'));
  });
});
