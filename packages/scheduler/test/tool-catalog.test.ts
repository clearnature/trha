// Tool catalog tests (tool-catalog concept): schema completeness and the
// derived model-facing spec.

import { describe, expect, it } from 'vitest';
import { findTool, toToolSpecs, toolCatalog, ToolDefinition } from '../src/Server/toolCatalog.js';

describe('toolCatalog', () => {
  it('offers the host tools in a stable order', () => {
    // bash first: the model-facing order is the order in the catalog, and a
    // coding agent without a shell cannot verify anything it writes.
    expect(toolCatalog.map(t => t.name)).toEqual(['bash', 'read_file', 'write_file', 'append_file']);
  });

  it('every tool carries name/description and a valid parameter schema', () => {
    for (const t of toolCatalog) {
      expect(t.name.length).toBeGreaterThan(0);
      expect(t.description.length).toBeGreaterThan(0);
      expect(t.parameters.type).toBe('object');
      for (const req of t.parameters.required) {
        expect(t.parameters.properties[req]).toBeDefined();
      }
    }
  });

  it('bash requires a command; write/append require path + content; read requires path', () => {
    const bash = toolCatalog.find(t => t.name === 'bash') as ToolDefinition;
    expect(bash.parameters.required).toEqual(['command']);
    const read = toolCatalog.find(t => t.name === 'read_file') as ToolDefinition;
    const write = toolCatalog.find(t => t.name === 'write_file') as ToolDefinition;
    expect(read.parameters.required).toEqual(['path']);
    expect(write.parameters.required).toEqual(['path', 'content']);
  });

  it('findTool resolves by name', () => {
    expect(findTool('read_file')?.name).toBe('read_file');
    expect(findTool('nope')).toBeUndefined();
  });

  it('toToolSpecs flattens the catalog to the wire shape', () => {
    const specs = toToolSpecs();
    expect(specs).toHaveLength(4);
    expect(specs[0]).toMatchObject({ name: 'bash', description: expect.any(String), parameters: { type: 'object' } });
    expect(specs[1]).toMatchObject({ name: 'read_file', description: expect.any(String), parameters: { type: 'object' } });
  });
});
