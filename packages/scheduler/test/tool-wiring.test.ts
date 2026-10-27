// Wiring parity: the tool catalog, the model-facing spec and the executor's
// dispatch tables must describe the same set of tools.
//
// This is the regression guard for the bug class we actually hit: a tool that
// is advertised (catalog → the model, /api/tools → the UI) with no handler, or
// a handler reachable only by a name nobody can be told about.  The old
// hand-written ALL_TOOLS list was exactly the first kind — 44 advertised names
// with no executor — and nothing failed until a model called one of them.

import { describe, expect, it } from 'vitest';
import { toolCatalog } from '../src/Server/toolCatalog.js';
import { STANDARD_TOOL_NAMES } from '../src/Server/standardTools.js';
import { EXTRA_TOOL_NAMES } from '../src/Server/extraTools.js';

// Implemented inline in Server/index.ts `executeTool` (filesystem + shell), so
// they do not live in either dispatch table.
const INLINE_TOOL_NAMES = [
  'bash', 'read', 'write', 'edit', 'glob', 'grep', 'append_file',
];

const dispatched = new Set<string>([
  ...INLINE_TOOL_NAMES,
  ...STANDARD_TOOL_NAMES,
  ...EXTRA_TOOL_NAMES,
]);

describe('tool wiring parity', () => {
  it('catalog names are unique', () => {
    const seen = new Set<string>();
    const dupes: string[] = [];
    for (const t of toolCatalog) {
      if (seen.has(t.name)) dupes.push(t.name);
      seen.add(t.name);
    }
    expect(dupes).toEqual([]);
  });

  it('every catalogued tool has a handler', () => {
    // A catalog entry with no handler is a promise the executor cannot keep.
    expect(toolCatalog.map(t => t.name).filter(n => !dispatched.has(n))).toEqual([]);
  });

  it('every dispatched name is catalogued', () => {
    // The reverse: a handler nobody can discover is dead code (or a typo in one
    // of the three tables — e.g. `ask_user` vs `ask_user_question`).
    const catalogued = new Set(toolCatalog.map(t => t.name));
    expect([...dispatched].filter(n => !catalogued.has(n)).sort()).toEqual([]);
  });
});
