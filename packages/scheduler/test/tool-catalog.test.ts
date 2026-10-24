// Tool catalog tests: schema completeness and the derived model-facing spec.

import { describe, expect, it } from 'vitest';
import { canonicalToolName, findTool, toToolSpecs, toolCatalog, type ToolDefinition } from '../src/Server/toolCatalog.js';

describe('toolCatalog', () => {
  it('offers the host tools in a stable order', () => {
    // Names follow deepseek-harness; a coding agent needs a shell to verify
    // anything it writes, so bash comes first.
    expect(toolCatalog.map(t => t.name))
      .toEqual([
        'bash', 'read', 'write', 'edit', 'glob', 'grep',
        'ask_user_question', 'exit_plan_mode', 'present', 'run_code', 'read_image',
        'todo_write', 'create_goal', 'get_goal', 'update_goal',
        'schedule_create', 'schedule_list', 'schedule_update', 'schedule_delete',
        'job_list', 'job_output', 'job_kill', 'skill', 'web_fetch',
        'append_file',
      ]);
  });

  it('maps the legacy file-tool names onto the canonical ones', () => {
    expect(canonicalToolName('read_file')).toBe('read');
    expect(canonicalToolName('write_file')).toBe('write');
    expect(canonicalToolName('edit_file')).toBe('edit');
    expect(canonicalToolName('bash')).toBe('bash');
  });

  it('every definition is well formed', () => {
    for (const t of toolCatalog) {
      expect(t.name.length).toBeGreaterThan(0);
      expect(t.description.length).toBeGreaterThan(0);
      expect(t.parameters.type).toBe('object');
      for (const req of t.parameters.required) {
        expect(t.parameters.properties[req]).toBeDefined();
      }
    }
  });

  it('declares the required fields each tool actually needs', () => {
    const byName = (n: string) => toolCatalog.find(t => t.name === n) as ToolDefinition;
    expect(byName('bash').parameters.required).toEqual(['command']);
    expect(byName('read').parameters.required).toEqual(['path']);
    expect(byName('write').parameters.required).toEqual(['path', 'content']);
    expect(byName('edit').parameters.required).toEqual(['path', 'old_string', 'new_string']);
    expect(byName('glob').parameters.required).toEqual(['pattern']);
    expect(byName('grep').parameters.required).toEqual(['pattern']);
  });

  it('findTool resolves by name', () => {
    expect(findTool('read')?.name).toBe('read');
    expect(findTool('nope')).toBeUndefined();
  });

  it('toToolSpecs flattens the catalog to the wire shape', () => {
    const specs = toToolSpecs();
    expect(specs).toHaveLength(toolCatalog.length);
    expect(specs[0]).toMatchObject({
      name: 'bash', description: expect.any(String), parameters: { type: 'object' },
    });
    expect(specs[1]).toMatchObject({ name: 'read', parameters: { type: 'object' } });
    expect(specs.map(s => Object.keys(s).sort())).toEqual(
      specs.map(() => ['description', 'name', 'parameters']),
    );
  });
});
