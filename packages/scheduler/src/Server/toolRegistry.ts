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

export type ToolPlane = 'host' | 'agent';

/** Host objects differ per call site; handlers narrow it themselves. */
export type ToolHandler = (args: Record<string, unknown>, host: unknown) => Promise<string>;

export interface ToolSpec {
  name: string;
  /**
   * `host` = process-wide singleton row (registry/service owner), `agent` =
   * a model-facing row a preset chooses to mount.
   */
  plane: ToolPlane;
  /** Preset ids that expose this tool; omitted = every preset. */
  presets?: string[];
  /**
   * Absent = **declared but not migrated yet**: the entry points fall through to
   * the legacy if-chain. This lets the plane/preset metadata land in one pass
   * (so filtering works immediately) while handlers move over one by one.
   */
  handler?: ToolHandler;
}

const registry = new Map<string, ToolSpec>();

/** Register one tool. Duplicate names are a programming error, not a merge. */
export function registerTool(spec: ToolSpec): void {
  if (registry.has(spec.name)) {
    throw new Error(`tool "${spec.name}" is already registered`);
  }
  registry.set(spec.name, spec);
}

export function resolveTool(name: string): ToolSpec | undefined {
  return registry.get(name);
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
