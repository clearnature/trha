import { describe, expect, it } from 'vitest';
import { groupTurns } from '../src/layout/turns';
import type { Message } from '../src/types';

const m = (role: Message['role'], content: string): Message => ({ role, content });

describe('groupTurns', () => {
  it('starts a turn at each user message', () => {
    const turns = groupTurns([m('user', 'a'), m('assistant', 'b'), m('user', 'c'), m('assistant', 'd')]);
    expect(turns).toHaveLength(2);
    expect(turns[0].messages.map(x => x.content)).toEqual(['a', 'b']);
    expect(turns[1].messages.map(x => x.content)).toEqual(['c', 'd']);
  });

  it('keeps a leading assistant row in its own turn', () => {
    const turns = groupTurns([m('assistant', 'hi'), m('user', 'q')]);
    expect(turns.map(t => t.messages.map(x => x.role))).toEqual([
      ['assistant'], ['user'],
    ]);
  });

  it('indexes turns in order', () => {
    const turns = groupTurns([m('user', 'a'), m('user', 'b')]);
    expect(turns.map(t => t.index)).toEqual([0, 1]);
  });

  it('is empty without messages', () => {
    expect(groupTurns([])).toEqual([]);
  });
});
