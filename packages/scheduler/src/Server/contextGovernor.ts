// Context governance: keep requests inside the model window without wrecking
// the prefix cache.
//
// Two costs pull in opposite directions. Growing without bound eventually
// overflows the window; rewriting history invalidates the provider's prefix
// cache (the whole prefix becomes a miss). So maintenance is threshold-driven
// and rare, and when it fires it lands on a *stable* new prefix that later turns
// only append to.
//
// Thresholds mirror the Reasonix harness (snip 60% / fold 80% / force 90% of the
// window, recent tail kept verbatim at 16%), including the economics rule: a
// region smaller than `minFoldTokens` is not worth a pass.
//
// Folding here is deterministic (no summarizer call), so a pass costs no tokens.
// It is lossy by design — the alternative is a paid summarization round-trip per
// fold, which is a later upgrade, not a default.

export interface GovernedMessage {
  role: string;
  content: string;
  tool_calls?: unknown[] | undefined;
  tool_call_id?: string | undefined;
  [key: string]: unknown;
}

export interface GovernanceConfig {
  /** Model window in tokens. */
  window: number;
  snipRatio: number;
  foldRatio: number;
  forceRatio: number;
  /** Share of the window kept verbatim as the recent tail. */
  tailRatio: number;
  /** Below this, compacting saves less than the pass costs. */
  minFoldTokens: number;
  /**
   * Keep the first user message verbatim when folding.
   *
   * It is usually the task statement — the one message whose loss is not
   * recoverable from later turns — and it costs a fraction of the span being
   * elided, so this is the cheapest quality/price win in the fold.
   */
  keepFirstUser: boolean;
  /**
   * Focus hint for one explicit /compact [focus] pass (T9b): messages whose
   * content matches (case-insensitive substring) are protected from elision —
   * snipped tool results keep their body, folded messages survive in order,
   * and their tool-call blocks stay atomic. Empty/absent = no protection and
   * behaviour identical to a pass without focus.
   */
  focus?: string;
}

export const DEFAULT_GOVERNANCE: GovernanceConfig = {
  window: 524_288,   // 500k: the working window, below the model's 1M capability
  snipRatio: 0.6,
  foldRatio: 0.8,
  forceRatio: 0.9,
  tailRatio: 0.16,
  minFoldTokens: 400,
  keepFirstUser: true,
};

export type GovernanceTrigger = 'none' | 'snip' | 'fold' | 'force';

export interface GovernanceResult<T extends GovernedMessage = GovernedMessage> {
  messages: T[];
  trigger: GovernanceTrigger;
  /** Prompt tokens the pass removed (upper bound: estimated from text). */
  savedTokens: number;
  /** True when the request prefix changed, i.e. the next call's cache misses. */
  prefixChanged: boolean;
  /** Messages kept verbatim because of the focus hint (0 without focus). */
  focusKept: number;
}

/** Cheap token estimate: CJK runs are ~1 token per char, ASCII ~1 per 3.5. */
export function estimateTokens(text: string): number {
  let cjk = 0;
  for (const ch of text) if (ch.codePointAt(0)! > 0x2e7f) cjk += 1;
  const ascii = text.length - cjk;
  return Math.ceil(cjk + ascii / 3.5);
}

export function estimateMessages(messages: readonly GovernedMessage[]): number {
  let total = 0;
  for (const m of messages) {
    total += 4 + estimateTokens(m.content ?? '');
    if (m.tool_calls) total += estimateTokens(JSON.stringify(m.tool_calls));
  }
  return total;
}

/**
 * Index where the verbatim tail starts, measured from the end.
 *
 * A tool block -- @assistant@ with @tool_calls@ plus the @tool@ messages that
 * answer it -- is atomic: splitting it leaves a tool result whose call was
 * elided, and a provider rejects that transcript with "insufficient tool
 * messages". So the boundary walks back over any tool message it lands on.
 */
function tailStart(messages: readonly GovernedMessage[], tailTokens: number): number {
  let budget = tailTokens;
  let i = messages.length;
  while (i > 0 && budget > 0) {
    i -= 1;
    budget -= 4 + estimateTokens(messages[i]?.content ?? '');
  }
  while (i > 0 && messages[i]?.role === 'tool') i -= 1;
  return i;
}

const SNIPPED = (n: number) => `[tool result elided: ${n} chars]`;

/** Case-insensitive focus match on message content. Empty focus never matches. */
function matchesFocus(m: GovernedMessage, focus: string): boolean {
  if (!focus) return false;
  const c = m.content ?? '';
  return c.toLowerCase().includes(focus.toLowerCase());
}

/**
 * Expand a seed set of protected indices to whole tool blocks.
 *
 * A `tool` result may never be kept without the `assistant` message that
 * carries its call (and the sibling results of that call), and vice versa —
 * splitting a block is exactly the "insufficient tool messages" provider
 * rejection the history invariants guard against.
 */
function expandProtected<T extends GovernedMessage>(messages: readonly T[], seed: Iterable<number>): Set<number> {
  const prot = new Set(seed);
  for (let i = 0; i < messages.length; i++) {
    if (!prot.has(i)) continue;
    const m = messages[i]!;
    if (m.role === 'tool' && m.tool_call_id) {
      // walk back to the assistant carrying this call, protect it + siblings
      let j = i - 1;
      while (j >= 0) {
        const p = messages[j]!;
        const calls = p.tool_calls ?? [];
        if (p.role === 'assistant' && calls.some(c => (c as { id?: string }).id === m.tool_call_id)) {
          prot.add(j);
          for (let k = j + 1; k <= i; k++) {
            const q = messages[k]!;
            if (q.role === 'tool' && q.tool_call_id && calls.some(c => (c as { id?: string }).id === q.tool_call_id)) prot.add(k);
          }
          break;
        }
        j -= 1;
      }
    } else if (m.role === 'assistant' && (m.tool_calls ?? []).length > 0) {
      // protect the tool results answering this call
      for (let k = i + 1; k < messages.length; k++) {
        const q = messages[k]!;
        if (q.role === 'tool' && q.tool_call_id && (m.tool_calls ?? []).some(c => (c as { id?: string }).id === q.tool_call_id)) {
          prot.add(k);
        } else if (q.role !== 'tool') break;
      }
    }
  }
  return prot;
}

/**
 * Replace the content of old tool results with a stable placeholder.
 *
 * Tool results are the largest and least reusable payloads in a long session,
 * so they go first — and the placeholder is a fixed string, so the rewritten
 * prefix stays byte-identical on later turns. Focus-matching results are the
 * one exception: the caller asked for them to survive this pass.
 *
 * Returns the rewritten messages and how many results focus protected.
 */
function snip(
  messages: readonly GovernedMessage[],
  keepFrom: number,
  focus: string,
): { out: GovernedMessage[]; focusKept: number } {
  let focusKept = 0;
  const out = messages.map((m, i) => {
    if (i >= keepFrom || m.role !== 'tool') return m;
    if (m.content.length <= 200) return m;
    if (matchesFocus(m, focus)) {
      focusKept += 1;
      return m;
    }
    return { ...m, content: SNIPPED(m.content.length) };
  });
  return { out, focusKept };
}

/**
 * Fold the span before the verbatim tail into one marker message.
 *
 * The marker carries counts, not content, and no timestamp — anything volatile
 * would change the prefix on every turn and defeat the cache.
 *
 * Focus-matching messages (and, per block atomicity, their whole tool blocks)
 * are kept verbatim, in original order, ahead of the marker; the marker's
 * counts describe only what was actually elided.
 */
function fold(
  messages: readonly GovernedMessage[],
  keepFrom: number,
  trigger: 'fold' | 'force',
  keepFirstUser: boolean,
  focus: string,
): { out: GovernedMessage[]; focusKept: number } {
  if (keepFrom <= 0) return { out: [...messages], focusKept: 0 };
  const tail = messages.slice(keepFrom);
  let elided = messages.slice(0, keepFrom);

  // The leading system block is never elided: it defines behaviour, it is the
  // part of the prefix most worth keeping cached, and losing it would change
  // how every later turn is answered.
  const head: GovernedMessage[] = [];
  while (elided.length > 0 && elided[0]!.role === 'system') head.push(elided.shift()!);

  // Preserve the opening user turn (the task statement) too: it is the one
  // message whose loss later turns cannot recover, and it costs a fraction of
  // the span being elided.
  const kept: GovernedMessage[] = [];
  if (keepFirstUser) {
    const firstUser = elided.findIndex(m => m.role === 'user');
    if (firstUser >= 0) kept.push(...elided.splice(firstUser, 1));
  }

  // Focus protection: block-atomic, order-preserving, applied to whatever is
  // still in the elidable span after the head and first-user extractions.
  let focusKept = 0;
  const focusKeptMsgs: GovernedMessage[] = [];
  if (focus) {
    const seed = new Set<number>();
    elided.forEach((m, i) => { if (matchesFocus(m, focus)) seed.add(i); });
    if (seed.size > 0) {
      const prot = expandProtected(elided, seed);
      for (let i = 0; i < elided.length; i++) {
        if (prot.has(i)) focusKeptMsgs.push(elided[i]!);
      }
      elided = elided.filter((_, i) => !prot.has(i));
      focusKept = focusKeptMsgs.length;
    }
  }

  const userTurns = elided.filter(m => m.role === 'user').length;
  const focusNote = focusKept > 0 ? `; focus "${focus}": ${focusKept} message(s) kept` : '';
  const marker: GovernedMessage = {
    role: 'user',
    content: `[context ${trigger === 'force' ? 'compacted' : 'folded'}: ${elided.length} earlier messages`
      + ` (${userTurns} user turns, ~${estimateMessages(elided)} tokens) elided to fit the window${focusNote}]`,
  };
  return { out: [...head, ...kept, ...focusKeptMsgs, marker, ...tail], focusKept };
}

/**
 * Decide and perform one maintenance pass.
 *
 * `latestPromptTokens` is the provider's own count from the previous request —
 * ground truth where available. Falls back to an estimate.
 */
export function govern<T extends GovernedMessage>(
  messages: readonly T[],
  latestPromptTokens: number,
  cfg: GovernanceConfig = DEFAULT_GOVERNANCE,
): GovernanceResult<T> {
  const pressure = latestPromptTokens > 0 ? latestPromptTokens : estimateMessages(messages);
  const focus = (cfg.focus ?? '').trim();
  const unchanged: GovernanceResult<T> = {
    messages: [...messages], trigger: 'none', savedTokens: 0, prefixChanged: false, focusKept: 0,
  };
  if (cfg.window <= 0 || pressure < cfg.window * cfg.snipRatio) return unchanged;

  const trigger: GovernanceTrigger =
    pressure >= cfg.window * cfg.forceRatio ? 'force'
    : pressure >= cfg.window * cfg.foldRatio ? 'fold'
    : 'snip';

  const keepFrom = tailStart(messages, cfg.window * cfg.tailRatio);
  const before = estimateMessages(messages);

  let next: T[];
  let focusKept = 0;
  if (trigger === 'snip') {
    const r = snip(messages, keepFrom, focus) as { out: T[]; focusKept: number };
    next = r.out;
    focusKept = r.focusKept;
  } else {
    const r = fold(messages, keepFrom, trigger, cfg.keepFirstUser, focus) as { out: T[]; focusKept: number };
    next = r.out;
    focusKept = r.focusKept;
  }

  const saved = Math.max(0, before - estimateMessages(next));
  // The economics rule: a fold that saves less than a small request would cost
  // is not worth the cache rebuild it causes.
  if (trigger !== 'snip' && saved < cfg.minFoldTokens) return unchanged;
  if (saved <= 0) return unchanged;

  return { messages: next, trigger, savedTokens: saved, prefixChanged: true, focusKept };
}
