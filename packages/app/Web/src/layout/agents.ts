// Agent tree projection for the sidebar (pure, testable without React).
//
// Sessions form a forest via `parentId`; rows are depth-first so a child
// always follows its parent, and the active session is marked.

import type { AgentEntry } from '../types';

export interface AgentRow {
  id: string;
  depth: number;
  current: boolean;
}

export function agentRows(agents: AgentEntry[], currentId?: string | null): AgentRow[] {
  const byParent = new Map<string | null, AgentEntry[]>();
  for (const a of agents) {
    const key = a.parentId ?? null;
    const list = byParent.get(key) ?? [];
    list.push(a);
    byParent.set(key, list);
  }
  const rows: AgentRow[] = [];
  const seen = new Set<string>();
  const walk = (parent: string | null, depth: number) => {
    for (const a of byParent.get(parent) ?? []) {
      if (seen.has(a.id)) continue;
      seen.add(a.id);
      rows.push({ id: a.id, depth, current: a.id === currentId });
      walk(a.id, depth + 1);
    }
  };
  walk(null, 0);
  return rows;
}
