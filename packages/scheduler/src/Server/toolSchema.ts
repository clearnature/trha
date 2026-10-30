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
}

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
