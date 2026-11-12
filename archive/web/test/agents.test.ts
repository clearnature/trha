import { describe, expect, it } from 'vitest';
import { agentRows } from '../src/layout/agents';

describe('agentRows', () => {
  it('walks parents before children with depth', () => {
    const rows = agentRows([
      { id: 'root-a' },
      { id: 'root-b' },
      { id: 'child-a1', parentId: 'root-a' },
      { id: 'grand-a1', parentId: 'child-a1' },
    ]);
    expect(rows.map(r => [r.id, r.depth])).toEqual([
      ['root-a', 0], ['child-a1', 1], ['grand-a1', 2], ['root-b', 0],
    ]);
  });

  it('marks the current session', () => {
    const rows = agentRows([{ id: 'a' }, { id: 'b', parentId: 'a' }], 'b');
    expect(rows.find(r => r.id === 'b')?.current).toBe(true);
    expect(rows.find(r => r.id === 'a')?.current).toBe(false);
  });

  it('never loops on a cyclic parent link', () => {
    const rows = agentRows([
      { id: 'x', parentId: 'y' },
      { id: 'y', parentId: 'x' },
    ]);
    expect(rows).toEqual([]);
  });

  it('is empty without sessions', () => {
    expect(agentRows([])).toEqual([]);
  });
});
