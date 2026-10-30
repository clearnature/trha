/**
 * Tool schema layer — the trha counterpart of DSH's `defineTool`.
 *
 * DSH declares every tool as a plugin (`packages/session/tool-working-directory/src/index.ts`):
 *
 * ```ts
 * export const name = 'tool-working-directory'
 * export const inject = ['tools', 'workingDirectory']
 * export function apply(ctx) {
 *   ctx.tools.register(defineTool({ name, description, parameters, output, execute }))
 * }
 * ```
 *
 * with the contract `name` + `description` + `parameters` + `output { schema, render }`
 * + `execute(args, exec)`. trha's tools were `(args, host) => string` branches inside
 * two if-chains, which cannot express any of it: no parameter schema, no canonical
 * output value, no render separation, no cancellation.
 *
 * This module closes that gap. The **shape** is DSH's; the implementation is
 * trha's (no Cordis, no inference-level generics).
 */

/** Model-facing render blocks. DSH calls these `ContentBlock[]`. */
export interface ContentBlock {
  type: 'text';
  text: string;
}

/**
 * Execution context handed to `execute` — DSH's `ToolRunContext`, narrowed to
 * what trha can actually supply today (`agent`/`signal` come from the call
 * site; `host` is the scheduler's service bag).
 */
export interface ToolExecContext {
  /** Session the call belongs to; undefined for non-agent callers. */
  agent?: string;
  /** Caller cancellation. Tools must forward or observe it. */
  signal?: AbortSignal;
  /** trha's service bag (cwd, workspaceRoot, jobs, …). */
  host: unknown;
}

export interface ToolOutputDefinition<T = unknown> {
  /** Schema enforced against every successful value. */
  schema: Record<string, unknown>;
  /** Pure render of one validated canonical value into model-facing blocks. */
  render: (args: Record<string, unknown>, value: T) => ContentBlock[];
  /** Replayable presentation metadata for native and nested calls. */
  presentationMeta?: (args: Record<string, unknown>, value: T) => unknown;
}

/**
 * DSH's `ToolCallView`, reduced to what a card actually needs today.
 *
 * A tool returns one of these from `presentCall` to describe how THIS call
 * should be labelled — the alternative is every shell guessing from the raw
 * arguments. Tools that do not implement it get the generic card.
 */
export interface ToolCallView {
  /** Card treatment. `generic` is the default row. */
  card: 'generic' | 'terminal' | 'diff';
  /** Short, always-visible label for this specific call. */
  title: string;
  /** Salient input for the expanded view (a job id, a path, a command). */
  rawInput?: unknown;
}

// ─── DSH presentation types ────────────────────────────────────────────────
// Copied verbatim from `deepseek-harness/packages/core/tools/src/presentation.ts`.
// These are the types `presentResult` returns; keeping them byte-identical to
// upstream is the point — a UI bridge can then be ported without re-deciding
// field names or optionality.

/** One line of a read view: its 1-based file line number and text. */
export interface ReadFileLine {
  number: number;
  text: string;
}

/** One file-level change: prior content (null when new) and the result. */
export interface FileDiff {
  path: string;
  /** Prior content, or `null` for a new file / an overwrite (no prior content available at call time). */
  oldText: string | null;
  /** Content after the change. */
  newText: string;
}

/** One matched line inside a `SearchFileMatches` group. */
export interface SearchLineMatch {
  /** 1-based line number of the match within its file. */
  lineNumber: number;
  /** The matched line text, as the tool surfaced it (the per-line preview budget already applied). */
  line: string;
}

/** One file's grouped content matches, in first-seen file order. */
export interface SearchFileMatches {
  /** The file the matches belong to (the model-facing display path). */
  path: string;
  /** The file's matched lines, in output order. */
  matches: SearchLineMatch[];
}

/** One citeable source in a completed `WebSearchResultView`. */
export interface WebSource {
  /** The source URL. */
  url: string;
  /** The source title, when the provider returned one. */
  title?: string;
  /** A short excerpt or summary, when the provider returned one. */
  snippet?: string;
  /** Publication/crawl timestamp as a provider-supplied ISO-8601 string, when present. */
  publishedAt?: string;
}

/** The default completed card: an optional replacement title and reformatted content. */
export interface GenericResultView {
  card: 'generic';
  /** Replacement title for the completed call. Omit to keep the pending-state title. */
  title?: string;
  /** UI-facing result content, reformatted from the model-facing result. */
  content?: ContentBlock[];
}

/** A completed shell command: captured output plus its exit status. */
export interface TerminalResultView {
  card: 'terminal';
  /** Replacement title for the completed call. Omit to keep the pending-state title. */
  title?: string;
  /** Captured command output (stdout+stderr as the tool chooses to combine them). */
  output?: string;
  /** Process exit code, when the run ended by exiting (not a signal). */
  exitCode?: number;
  /** Signal name, when the run was killed by one. */
  signal?: string;
}

/** A completed file change. */
export interface DiffResultView {
  card: 'diff';
  /** Replacement title for the completed call. Omit to keep the pending-state title. */
  title?: string;
  /** The change to show, in file order. */
  diffs: FileDiff[];
}

/** A completed content search, grouped by file. */
export interface SearchMatchesResultView {
  card: 'search';
  shape: 'matches';
  /** Replacement title for the completed call. Omit to keep the pending-state title. */
  title?: string;
  /** Matched lines grouped by file, in first-seen file order. */
  files: SearchFileMatches[];
  /** Whether the tool capped the inline result. */
  truncated: boolean;
  /** Total matches the search found before capping. */
  total: number;
}

/** A completed path search, as a flat path list. */
export interface SearchPathsResultView {
  card: 'search';
  shape: 'paths';
  /** Replacement title for the completed call. Omit to keep the pending-state title. */
  title?: string;
  /** The discovered paths, in the tool's result order. */
  paths: string[];
  /** Whether the tool capped the inline result. */
  truncated: boolean;
  /** Total paths the search found before capping. */
  total: number;
}

/** A completed search rendered as a search card. */
export type SearchResultView = SearchMatchesResultView | SearchPathsResultView;

/** A completed file read rendered as a line-numbered code view. */
export interface ReadResultView {
  card: 'read';
  /** Replacement title for the completed call. Omit to keep the pending-state title. */
  title?: string;
  /** The read file's path (the model-facing path; the bridge relativizes it). */
  path: string;
  /** The 1-based first line the window requested. */
  offset: number;
  /** The returned window's lines, in file order, each keeping its file line number. */
  lines: ReadFileLine[];
  /** Exact total line count in the file. */
  totalLines: number;
  /** A syntax-highlighting language hint derived from the file extension. */
  lang?: string;
  /** The model-facing result content with its envelope stripped. */
  content?: ContentBlock[];
}

/** The completed state of a `web_search` call. */
export interface WebSearchResultView {
  card: 'web';
  kind: 'search';
  /** Replacement title for the completed call. Omit to keep the pending-state title. */
  title?: string;
  /** The faithful, structured sources. */
  sources: WebSource[];
  /** The provider-generated answer text, when any. */
  answer?: string;
  /** True when the web service cut the source list to honor the result cap. */
  truncated: boolean;
}

/** The completed state of a `web_fetch` call. */
export interface WebFetchResultView {
  card: 'web';
  kind: 'fetch';
  /** Replacement title for the completed call. Omit to keep the pending-state title. */
  title?: string;
  /** The final URL after allowed redirects. */
  url: string;
  /** HTTP status code of the fetched response. */
  statusCode: number;
  /** True when the provider capped the decoded body or a cap trimmed the text. */
  truncated: boolean;
}

/** How a tool wants the COMPLETED call shown — the *result* state, after `execute` returns. */
export type ToolResultView =
  | GenericResultView
  | TerminalResultView
  | DiffResultView
  | SearchResultView
  | ReadResultView
  | WebSearchResultView
  | WebFetchResultView;

/**
 * What a tool's execution produced, as the core sees it (DSH's `ToolResult`).
 *
 * NOTE: DSH passes this to `presentResult`; trha still passes the bare canonical
 * value. Closing that gap means porting each `presentResult` body from
 * `deepseek-harness` verbatim (`presentBashResult`, `presentGrepResult`,
 * `presentSearchResult`, `presentFetchResult`, `presentWorkflowResult`), so it is
 * tracked as its own task rather than half-done.
 *
 * Copied from `deepseek-harness/packages/core/tools/src/index.ts`:
 * `content` is model-facing, `isError` says whether the call failed, and `meta`
 * is the tool-private presentation payload projected by
 * `output.presentationMeta`, persisted on the tool result so replay can narrow
 * it independently. `meta` is absent when the tool declared no projector.
 */
export interface ToolResult {
  /** The final model-facing content (or the rendered error text on failure). */
  content: ContentBlock[];
  /** Whether the call failed. */
  isError: boolean;
  /** The tool-private presentation payload; absent when nothing was projected. */
  meta?: unknown;
}

export interface ToolDefinition<T = unknown> {
  name: string;
  /** Sent to the model. */
  description: string;
  /** Per-property parameter schema (DSH compiles an implicit open object). */
  parameters: Record<string, unknown>;
  output: ToolOutputDefinition<T>;
  /** Run one call and return the canonical value declared by `output.schema`. */
  execute: (args: Record<string, unknown>, exec: ToolExecContext) => Promise<T>;
  /** Cooperative timeout budget in milliseconds. */
  timeoutMs?: number;
  /** Ask the model loop to load this definition lazily. */
  deferLoading?: boolean;
  /** May this call join a parallel group? */
  isConcurrencySafe?: (args: Record<string, unknown>) => boolean;
  /**
   * Pure pending-state presenter: how this call should be labelled. `undefined`
   * means "use the generic card".
   */
  presentCall?: (args: Record<string, unknown>) => ToolCallView | undefined;
  /**
   * Pure completed-state presenter (DSH's `presentResult`): what the closing
   * card should say. Receives the canonical value `execute` returned.
   * `undefined` keeps the opening card's label.
   */
  presentResult?: (args: Record<string, unknown>, result: unknown) => ToolCallView | undefined;
  /**
   * Last-mile content transform, applied after `output.render` (DSH's
   * `projectContent` + `finalizeContent`, merged because trha has no
   * result-policy layer). Returning `undefined` keeps the rendered blocks.
   */
  finalizeContent?: (
    exec: { args: Record<string, unknown>; host: unknown },
    result: { value: T; content: ContentBlock[] },
  ) => ContentBlock[] | undefined;
}

/**
 * Every field of `ToolDefinition`, enumerated once.
 *
 * Adding a field to the interface without adding it here is a **type error** —
 * that is the whole point. Twice before, a field was declared and the
 * hand-written copy in `toolSpecFrom` silently dropped it, so 74 tools carried
 * a setting that never took effect. `Record<keyof T, true>` turns "remember to
 * copy it" into "the compiler tells you".
 */
export const DEFINITION_FIELDS: Record<keyof ToolDefinition, true> = {
  name: true,
  description: true,
  parameters: true,
  output: true,
  execute: true,
  timeoutMs: true,
  deferLoading: true,
  isConcurrencySafe: true,
  presentCall: true,
  presentResult: true,
  finalizeContent: true,
};

/**
 * Validate and return a tool definition.
 *
 * DSH enforces this through the type system (`InferArgs`/`InferValue`); trha
 * checks at construction instead — the same guarantee, caught one step earlier
 * than a runtime call.
 */
export function defineTool<T>(def: ToolDefinition<T>): ToolDefinition<T> {
  if (!def.name) throw new Error('defineTool: name is required');
  if (!def.description) throw new Error(`defineTool(${def.name}): description is required`);
  if (typeof def.execute !== 'function') {
    throw new Error(`defineTool(${def.name}): execute is required`);
  }
  if (!def.output || typeof def.output.render !== 'function') {
    throw new Error(`defineTool(${def.name}): output.render is required`);
  }
  return def;
}

/** The single text block most tools render to. */
/** Collapse whitespace and clip, for one-line card titles. */
export const oneLine = (value: unknown, max = 48): string => {
  const text = String(value ?? '').replace(/\s+/g, ' ').trim();
  return text.length > max ? `${text.slice(0, max)}…` : text;
};

export function textBlock(text: string): ContentBlock {
  return { type: 'text', text };
}

/**
 * Declared service dependency of a tool plugin — DSH's `export const inject`.
 * Kept as data so the registry can report what a plugin needs.
 */
export interface ToolPlugin {
  name: string;
  inject?: string[];
  apply: (ctx: ToolPluginContext) => void | Promise<void>;
}

export interface ToolPluginContext {
  /** Register one tool; the returned function unregisters it. */
  register: (def: ToolDefinition) => () => void;
  /** Resolve a dependency declared in `inject`. */
  resolve: (service: string) => unknown;
}

/**
 * Bridge a DSH-shaped `ToolDefinition` into a registry `ToolSpec`.
 *
 * Kept in this direction (`schema → registry`) so the registry never has to
 * import the schema layer: legacy tools can still register with a bare
 * `handler`, and migrated ones carry the full contract.
 */
export function toolSpecFrom<T>(
  def: ToolDefinition<T>,
  opts: { plane: ToolSpecPlane; origin?: ToolSpecOrigin; presets?: string[] },
): ToolSpecShape {
  return {
    name: def.name,
    plane: opts.plane,
    ...(opts.origin === undefined ? {} : { origin: opts.origin }),
    ...(opts.presets === undefined ? {} : { presets: opts.presets }),
    description: def.description,
    parameters: def.parameters,
    output: {
      schema: def.output.schema,
      render: (args, value) => def.output.render(args, value as T),
      ...(def.output.presentationMeta === undefined
        ? {}
        : { presentationMeta: (args: Record<string, unknown>, value: unknown) =>
            def.output.presentationMeta!(args, value as T) }),
    },
    ...(def.timeoutMs === undefined ? {} : { timeoutMs: def.timeoutMs }),
    // DSH declares these on the tool; dropping them here would make a tool that
    // sets `deferLoading` or `isConcurrencySafe` silently lose the setting.
    ...(def.deferLoading === undefined ? {} : { deferLoading: def.deferLoading }),
    ...(def.isConcurrencySafe === undefined
      ? {}
      : { isConcurrencySafe: (args: Record<string, unknown>) => def.isConcurrencySafe!(args) }),
    ...(def.presentCall === undefined
      ? {}
      : { presentCall: (args: Record<string, unknown>) => def.presentCall!(args) }),
    ...(def.presentResult === undefined
      ? {}
      : { presentResult: (args: Record<string, unknown>, result: unknown) =>
          def.presentResult!(args, result) }),
    ...(def.finalizeContent === undefined
      ? {}
      : {
          finalizeContent: (
            exec: { args: Record<string, unknown>; host: unknown },
            result: { value: unknown; content: ContentBlock[] },
          ) =>
            def.finalizeContent!(exec, {
              value: result.value as T,
              content: result.content,
            }),
        }),
    handler: (args, exec) => def.execute(args, exec),
  };
}

/** Structural aliases so this module stays independent of the registry's types. */
export type ToolSpecPlane = 'host' | 'agent';
export type ToolSpecOrigin = 'builtin' | 'external';
export interface ToolSpecShape {
  name: string;
  plane: ToolSpecPlane;
  origin?: ToolSpecOrigin;
  presets?: string[];
  description?: string;
  parameters?: Record<string, unknown>;
  output?: {
    schema: Record<string, unknown>;
    render: (args: Record<string, unknown>, value: unknown) => ContentBlock[];
    presentationMeta?: (args: Record<string, unknown>, value: unknown) => unknown;
  };
  timeoutMs?: number;
  handler?: (args: Record<string, unknown>, exec: ToolExecContext) => Promise<unknown>;
}
