// Tool schema catalog (aligned with deepseek-harness docs/tool-catalog):
// the schema and contract of every host tool live in one module so the
// model-facing tool list, the registry description and the guard rails
// share a single source of truth.
//
// Names follow deepseek-harness (`read`, `write`, `edit`, `glob`, `grep`,
// `bash`) so a model trained on that harness does not have to guess. The older
// `*_file` names stay as aliases in the executor.

export interface ToolDefinition {
  name: string;
  description: string;
  parameters: {
    type: 'object';
    properties: Record<string, unknown>;
    required: string[];
  };
}

/** Canonical tool directory, in the order offered to the model. */
export const toolCatalog: ToolDefinition[] = [
  {
    name: 'bash',
    description: 'Execute a shell command in the workspace (stdout+stderr, exit code included)',
    parameters: {
      type: 'object',
      properties: { command: { type: 'string' } },
      required: ['command'],
    },
  },
  {
    name: 'read',
    description: 'Read a file (optionally a line range). Returns numbered lines.',
    parameters: {
      type: 'object',
      properties: {
        path: { type: 'string' },
        offset: { type: 'number', description: '1-based first line' },
        limit: { type: 'number', description: 'max lines to return' },
      },
      required: ['path'],
    },
  },
  {
    name: 'write',
    description: 'Write a file (creates/overwrites) inside the workspace',
    parameters: {
      type: 'object',
      properties: { path: { type: 'string' }, content: { type: 'string' } },
      required: ['path', 'content'],
    },
  },
  {
    name: 'edit',
    description: 'Replace an exact string in a file; old_string must match exactly once unless replace_all is set',
    parameters: {
      type: 'object',
      properties: {
        path: { type: 'string' },
        old_string: { type: 'string' },
        new_string: { type: 'string' },
        replace_all: { type: 'boolean' },
      },
      required: ['path', 'old_string', 'new_string'],
    },
  },
  {
    name: 'glob',
    description: 'List files matching a glob pattern (e.g. "src/**/*.ts"), newest first',
    parameters: {
      type: 'object',
      properties: {
        pattern: { type: 'string' },
        path: { type: 'string', description: 'directory to search from' },
      },
      required: ['pattern'],
    },
  },
  {
    name: 'grep',
    description: 'Search file contents with a regular expression; returns path:line:text',
    parameters: {
      type: 'object',
      properties: {
        pattern: { type: 'string' },
        path: { type: 'string', description: 'directory to search from' },
        glob: { type: 'string', description: 'only search files matching this glob' },
      },
      required: ['pattern'],
    },
  },
  {
    name: 'append_file',
    description: 'Append text to a file inside the workspace (creates if missing)',
    parameters: {
      type: 'object',
      properties: { path: { type: 'string' }, content: { type: 'string' } },
      required: ['path', 'content'],
    },
  },
];

/** Flat model-facing spec (name/description/parameters at the top level,
 * matching the bridge wire format). */
export interface ToolSpec {
  name: string;
  description: string;
  parameters: ToolDefinition['parameters'];
}

export function toToolSpecs(defs: ToolDefinition[] = toolCatalog): ToolSpec[] {
  return defs.map(d => ({
    name: d.name,
    description: d.description,
    parameters: d.parameters,
  }));
}

/** Look a tool definition up by name (for execute-side validation). */
export function findTool(name: string, defs: ToolDefinition[] = toolCatalog): ToolDefinition | undefined {
  return defs.find(d => d.name === name);
}

/** Older names kept working, mapped onto the canonical ones. */
export const TOOL_ALIASES: Record<string, string> = {
  read_file: 'read',
  write_file: 'write',
  write_to_file: 'write',
  edit_file: 'edit',
  apply_patch: 'edit',
  list_dir: 'glob',
  list_files: 'glob',
};

export function canonicalToolName(name: string): string {
  return TOOL_ALIASES[name] ?? name;
}
