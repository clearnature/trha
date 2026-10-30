/**
 * Tool registry — the seam that turns tools into plugins.
 *
 * Today every tool is a branch in one of two giant if-chains
 * (`runStandardTool`, `runExtraTool`), so a preset cannot decide *which* tools
 * its agents see: `standard`, `minimal` and `cordis` all get the same 74.
 * DSH solves this by registering tools as plugins on two planes:
 *
 *   - **host-plane** — process singletons the tools resolve (subagent registry,
 *     fs service, sandbox policy). Registered once per process.
 *   - **agent-plane** — the model-facing tool rows a preset mounts for its own
 *     agents.
 *
 * This module is step 1 of that migration: a registry plus a preset filter.
 * The chains stay in place as a fallback, so unregistered tools keep working
 * and migration can proceed one tool at a time with no big-bang rewrite.
 */

import type { ContentBlock, ToolExecContext } from './toolSchema.js';

export type ToolPlane = 'host' | 'agent';

/**
 * Where a tool comes from. This is orthogonal to `plane`:
 *
 * |            | builtin (ships with the harness) | external (loaded at runtime) |
 * |------------|----------------------------------|------------------------------|
 * | host-plane | subagent registry, goals        | a preset's own singleton      |
 * | agent-plane| bash, read, web_search          | `~/.trha/plugins/*.mjs`       |
 *
 * The two differ in management, not scope: builtins are fixed at import time,
 * externals are installed/removed at runtime and hot-reloaded by the watcher.
 */
export type ToolOrigin = 'builtin' | 'external';

/** Host objects differ per call site; handlers narrow it themselves. */
export type ToolHandler = (
  args: Record<string, unknown>,
  exec: ToolExecContext,
) => Promise<unknown>;

/**
 * Run a registered tool and turn its canonical value into model-facing text.
 *
 * This is the DSH split: `execute` returns a validated value, `output.render`
 * turns that value into content blocks. Tools that have not migrated yet return
 * a plain string, which passes through unchanged.
 *
 * A declared `timeoutMs` is a **cooperative** budget (DSH's wording): it rejects
 * the promise but cannot hard-kill the work, which is stated on purpose rather
 * than pretending the call was cancelled.
 */
export async function renderToolValue(
  spec: ToolSpec,
  args: Record<string, unknown>,
  host: unknown,
): Promise<string> {
  const value = await withTimeout(
    spec.handler!(args, { host }),
    spec.timeoutMs,
    spec.name,
  );
  const blocks: Array<{ type: 'text'; text: string }> = spec.output
    ? spec.output.render(args, value)
    : [{ type: 'text', text: typeof value === 'string' ? value : JSON.stringify(value) }];
  // DSH's `finalizeContent`: the last word on what reaches the model. Returning
  // `undefined` keeps the rendered blocks, so a tool that does not set the hook
  // behaves exactly as before.
  const finalized = spec.finalizeContent?.({ args, host }, { value, content: blocks });
  return (finalized ?? blocks).map((b: ContentBlock) => b.text).join('\n');
}

async function withTimeout<T>(work: Promise<T>, ms: number | undefined, name: string): Promise<T> {
  if (ms === undefined) return work;
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([
      work,
      new Promise<never>((_, reject) => {
        timer = setTimeout(
          () => reject(new Error(`tool ${name} exceeded its ${ms} ms budget`)),
          ms,
        );
      }),
    ]);
  } finally {
    if (timer !== undefined) clearTimeout(timer);
  }
}

export interface ToolSpec {
  name: string;
  /**
   * `host` = process-wide singleton row (registry/service owner), `agent` =
   * a model-facing row a preset chooses to mount.
   */
  plane: ToolPlane;
  /** Defaults to `builtin`; external plugins register with `external`. */
  origin?: ToolOrigin;
  /** Preset ids that expose this tool; omitted = every preset. */
  presets?: string[];
  /**
   * Absent = **declared but not migrated yet**: the entry points fall through to
   * the legacy if-chain. This lets the plane/preset metadata land in one pass
   * (so filtering works immediately) while handlers move over one by one.
   */
  handler?: ToolHandler;

  // ── DSH `defineTool` contract (optional while tools migrate) ──────────
  /** Sent to the model. */
  description?: string;
  /** Per-property parameter schema. */
  parameters?: Record<string, unknown>;
  /** Canonical output schema + render (DSH's `output`). */
  output?: {
    schema: Record<string, unknown>;
    render: (args: Record<string, unknown>, value: unknown) => Array<{ type: 'text'; text: string }>;
    presentationMeta?: (args: Record<string, unknown>, value: unknown) => unknown;
  };
  /** Cooperative timeout budget in milliseconds. */
  timeoutMs?: number;
  /**
   * DSH's `projectContent` / `finalizeContent`: a last-mile content transform
   * applied to every normalized outcome, after `output.render`. Returning
   * `undefined` preserves the rendered blocks.
   */
  finalizeContent?: (
    exec: { args: Record<string, unknown>; host: unknown },
    result: { value: unknown; content: Array<{ type: 'text'; text: string }> },
  ) => Array<{ type: 'text'; text: string }> | undefined;
  /** Ask the model loop to load this definition lazily (DSH's `deferLoading`). */
  deferLoading?: boolean;
  /** May this call join a parallel group? (DSH's `isConcurrencySafe`.) */
  isConcurrencySafe?: (args: Record<string, unknown>) => boolean;
  /** How this call should be labelled (DSH's `presentCall`). */
  presentCall?: (args: Record<string, unknown>) => {
    card: 'generic' | 'terminal' | 'diff';
    title: string;
    rawInput?: unknown;
  } | undefined;
}

const registry = new Map<string, ToolSpec>();

/**
 * Register one tool. A metadata-only declaration (`declareTool`) may later be
 * upgraded with a handler here; two handlers for the same name remain an error.
 */
export function registerTool(spec: ToolSpec): void {
  const existing = registry.get(spec.name);
  if (existing) {
    if (existing.handler) throw new Error(`tool "${spec.name}" is already registered`);
    existing.plane = spec.plane;
    if (spec.origin !== undefined) existing.origin = spec.origin;
    if (spec.presets !== undefined) existing.presets = spec.presets;
    if (spec.handler) existing.handler = spec.handler;
    return;
  }
  registry.set(spec.name, { origin: 'builtin', ...spec });
}

export function resolveTool(name: string): ToolSpec | undefined {
  return registry.get(name);
}

/**
 * Attach plane/preset metadata without a handler — idempotent, so a tool that
 * registered its own handler elsewhere (`web_fetch`) can still be declared here.
 */
export function declareTool(spec: Omit<ToolSpec, 'handler'>): void {
  const existing = registry.get(spec.name);
  if (existing) {
    existing.plane = spec.plane;
    if (spec.origin !== undefined) existing.origin = spec.origin;
    // `exactOptionalPropertyTypes` forbids assigning an explicit `undefined`.
    if (spec.presets !== undefined) existing.presets = spec.presets;
    return;
  }
  registry.set(spec.name, { origin: 'builtin', ...spec });
}

/** Every registered tool, optionally narrowed to one preset. */
export function listTools(preset?: string): ToolSpec[] {
  const all = [...registry.values()];
  if (preset === undefined) return all;
  return all.filter(t => t.presets === undefined || t.presets.includes(preset));
}

/**
 * Names a preset may expose. With no preset, every registered name is allowed
 * (the pre-migration behaviour).
 */
export function toolNamesForPreset(preset: string | undefined): Set<string> {
  return new Set(listTools(preset).map(t => t.name));
}

/** Test seam: clear the registry (vitest resets it between cases). */
export function resetToolRegistry(): void {
  registry.clear();
}

/**
 * Remove one tool. External plugins need this: `deactivate()` must undo what
 * `activate()` registered, the same way `ctx.on` returns a release handle.
 */
export function unregisterTool(name: string): void {
  registry.delete(name);
}
