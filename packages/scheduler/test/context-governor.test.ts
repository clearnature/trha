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

/** Every tool result must still have its call; every call its results. */
function orphans(messages: readonly GovernedMessage[]): string[] {
  const open = new Set<string>();
  const bad: string[] = [];
  messages.forEach((m, i) => {
    if (m.role === 'assistant' && (m.tool_calls ?? []).length) {
      const follow = messages.slice(i + 1, i + 1 + m.tool_calls!.length);
      if (follow.some(f => f.role !== 'tool')) bad.push(`call block at ${i} is split`);
      for (const c of m.tool_calls!) open.add(String((c as { id?: string }).id));
    }
    if (m.role === 'tool' && !open.has(String(m.tool_call_id))) {
      bad.push(`orphan tool result at ${i} (${m.tool_call_id})`);
    }
  });
  return bad;
}

describe('compaction never splits a tool block', () => {
  /** assistant(tool_calls) + tool result, repeated. */
  function toolRounds(n: number): GovernedMessage[] {
    const out: GovernedMessage[] = [
      { role: 'system', content: 'sys' },
      { role: 'user', content: 'task' },
    ];
    for (let i = 0; i < n; i++) {
      out.push({
        role: 'assistant', content: '',
        tool_calls: [{ id: `c${i}`, type: 'function', function: { name: 'bash', arguments: '{"command":"echo x"}' } }],
      });
      out.push({ role: 'tool', tool_call_id: `c${i}`, content: 'x'.repeat(400) });
    }
    return out;
  }

  it('walks the boundary back over a tool message', () => {
    const msgs = toolRounds(6);
    const cfg = { ...DEFAULT_GOVERNANCE, window: 2000, tailRatio: 0.12, minFoldTokens: 10 };
    const r = govern(msgs, 1900, cfg);
    expect(r.trigger).not.toBe('none');
    expect(orphans(r.messages)).toEqual([]);
  });

  it('holds for every tail budget across the block', () => {
    const msgs = toolRounds(8);
    for (let ratio = 0.05; ratio <= 0.5; ratio += 0.01) {
      const cfg = { ...DEFAULT_GOVERNANCE, window: 2000, tailRatio: ratio, minFoldTokens: 1 };
      const r = govern(msgs, 1900, cfg);
      expect(orphans(r.messages), `tailRatio=${ratio.toFixed(2)}`).toEqual([]);
    }
  });
});

describe('focus retention (T9b: /compact [focus])', () => {
  const FOCUSED = { ...SMALL, focus: 'needle' };

  it('snip keeps focus-matching tool results verbatim, snips the rest', () => {
    const big = 'y'.repeat(2000);
    const msgs: GovernedMessage[] = [
      { role: 'system', content: 'sys' },
      { role: 'user', content: 'do it' },
      { role: 'tool', tool_call_id: 'c1', content: 'the needle is here ' + big },
      { role: 'tool', tool_call_id: 'c2', content: big },
      { role: 'assistant', content: 'done' },
      ...conversation(8, 800).slice(1),
    ];
    const withFocus = govern(msgs, 6000, FOCUSED);
    expect(withFocus.trigger).toBe('snip');
    const t1 = withFocus.messages.find(m => m.tool_call_id === 'c1');
    expect(t1?.content).toContain('needle');                    // 保留正文
    const t2 = withFocus.messages.find(m => m.tool_call_id === 'c2');
    expect(t2?.content).toMatch(/^\[tool result elided: \d+ chars\]$/); // 其余照常
    expect(withFocus.focusKept).toBe(1);

    const without = govern(msgs, 6000, SMALL);
    expect(without.messages.find(m => m.tool_call_id === 'c1')?.content)
      .toMatch(/^\[tool result elided/);                        // 无 focus 时照常剪
  });

  it('fold keeps focus-matching messages in order, excluded from the marker', () => {
    const msgs: GovernedMessage[] = [
      { role: 'system', content: 'sys' },
      { role: 'user', content: 'task' },
      ...conversation(6, 800),
      { role: 'user', content: 'remember the needle spec: alpha-42' },
      ...conversation(3, 800),
    ];
    const r = govern(msgs, 9500, FOCUSED);       // 95% → force fold
    expect(['fold', 'force']).toContain(r.trigger);
    const keptMsg = r.messages.find(m => m.content.includes('alpha-42'));
    expect(keptMsg).toBeTruthy();                // focus 消息原文保留
    const marker = r.messages.find(m => String(m.content).startsWith('[context'));
    expect(String(marker?.content)).toContain('focus "needle": 1 message(s) kept');
    const keptIdx = r.messages.indexOf(keptMsg!);
    const markerIdx = r.messages.indexOf(marker!);
    expect(keptIdx).toBeLessThan(markerIdx);     // 保持原顺序：focus 在 marker 前
    expect(r.focusKept).toBe(1);
  });

  it('focus protection keeps tool blocks atomic', () => {
    const msgs: GovernedMessage[] = [
      { role: 'system', content: 'sys' },
      { role: 'user', content: 'task' },
      ...conversation(5, 800),
      { role: 'assistant', content: '', tool_calls: [
        { id: 'c1', type: 'function', function: { name: 'bash', arguments: '{}' } },
        { id: 'c2', type: 'function', function: { name: 'bash', arguments: '{}' } },
      ] },
      { role: 'tool', tool_call_id: 'c1', content: 'x'.repeat(400) },
      { role: 'tool', tool_call_id: 'c2', content: 'the needle reading: 42' },
      ...conversation(3, 800),
    ];
    const r = govern(msgs, 9500, FOCUSED);
    expect(['fold', 'force']).toContain(r.trigger);
    // c2 命中 focus ⇒ 其 assistant 调用与兄弟结果 c1 一并保留（块原子性）
    const asst = r.messages.find(m => (m.tool_calls ?? []).some(c => c.id === 'c1'));
    expect(asst).toBeTruthy();
    const i1 = r.messages.findIndex(m => m.tool_call_id === 'c1');
    const i2 = r.messages.findIndex(m => m.tool_call_id === 'c2');
    expect(i1).toBe(i2 - 1);
    const blocks = orphans(r.messages);
    expect(blocks).toEqual([]);
  });

  it('no-match focus behaves like no focus', () => {
    const msgs = conversation(10, 800);
    const withMiss = govern(msgs, 9500, { ...SMALL, focus: 'absent-term' });
    const plain = govern(msgs, 9500, SMALL);
    expect(withMiss.messages).toEqual(plain.messages);
    expect(withMiss.focusKept).toBe(0);
  });

  it('without focus the pass reports focusKept 0', () => {
    const r = govern(conversation(10, 800), 9500, SMALL);
    expect(r.focusKept).toBe(0);
  });
});
