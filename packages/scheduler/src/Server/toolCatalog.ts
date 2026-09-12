// Tool schema catalog (aligned with deepseek-harness docs/tool-catalog):
// the schema and contract of every host tool live in one module so the
// model-facing tool list, the registry description and the guard rails
// share a single source of truth.

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
    name: 'read_file',
    description: 'Read a file from the local filesystem',
    parameters: {
      type: 'object',
      properties: { path: { type: 'string' } },
      required: ['path'],
    },
  },
  {
    name: 'write_file',
    description: 'Write a file (creates/overwrites) inside the workspace',
    parameters: {
      type: 'object',
      properties: { path: { type: 'string' }, content: { type: 'string' } },
      required: ['path', 'content'],
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
