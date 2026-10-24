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

/**
 * Replace the content of old tool results with a stable placeholder.
 *
 * Tool results are the largest and least reusable payloads in a long session,
 * so they go first — and the placeholder is a fixed string, so the rewritten
 * prefix stays byte-identical on later turns.
 */
function snip(messages: readonly GovernedMessage[], keepFrom: number): GovernedMessage[] {
  return messages.map((m, i) => {
    if (i >= keepFrom || m.role !== 'tool') return m;
    if (m.content.length <= 200) return m;
    return { ...m, content: SNIPPED(m.content.length) };
  });
}

/**
 * Fold the span before the verbatim tail into one marker message.
 *
 * The marker carries counts, not content, and no timestamp — anything volatile
 * would change the prefix on every turn and defeat the cache.
 */
function fold(
  messages: readonly GovernedMessage[],
  keepFrom: number,
  trigger: 'fold' | 'force',
  keepFirstUser: boolean,
): GovernedMessage[] {
  if (keepFrom <= 0) return [...messages];
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

  const userTurns = elided.filter(m => m.role === 'user').length;
  const marker: GovernedMessage = {
    role: 'user',
    content: `[context ${trigger === 'force' ? 'compacted' : 'folded'}: ${elided.length} earlier messages`
      + ` (${userTurns} user turns, ~${estimateMessages(elided)} tokens) elided to fit the window]`,
  };
  return [...head, ...kept, marker, ...tail];
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
  const unchanged: GovernanceResult<T> = {
    messages: [...messages], trigger: 'none', savedTokens: 0, prefixChanged: false,
  };
  if (cfg.window <= 0 || pressure < cfg.window * cfg.snipRatio) return unchanged;

  const trigger: GovernanceTrigger =
    pressure >= cfg.window * cfg.forceRatio ? 'force'
    : pressure >= cfg.window * cfg.foldRatio ? 'fold'
    : 'snip';

  const keepFrom = tailStart(messages, cfg.window * cfg.tailRatio);
  const before = estimateMessages(messages);

  const next: T[] =
    trigger === 'snip'
      ? (snip(messages, keepFrom) as T[])
      : (fold(messages, keepFrom, trigger, cfg.keepFirstUser) as T[]);

  const saved = Math.max(0, before - estimateMessages(next));
  // The economics rule: a fold that saves less than a small request would cost
  // is not worth the cache rebuild it causes.
  if (trigger !== 'snip' && saved < cfg.minFoldTokens) return unchanged;
  if (saved <= 0) return unchanged;

  return { messages: next, trigger, savedTokens: saved, prefixChanged: true };
}
