// Guards the contract against the failure mode that already happened twice: a
// field declared on `ToolDefinition` but silently dropped on the way to
// `ToolSpec`, so every tool that set it carried a setting with no effect.
//
// `DEFINITION_FIELDS` is typed `Record<keyof ToolDefinition, true>`, so adding a
// field to the interface without listing it there fails to compile. This file
// closes the other half: the runtime assertion that a listed field actually
// arrives.
import { describe, expect, it } from 'vitest';
import { DEFINITION_FIELDS, defineTool, toolSpecFrom } from '../src/Server/toolSchema.js';
import { toToolSpecs } from '../src/Server/toolCatalog.js';

describe('tool contract completeness', () => {
  it('every declared field reaches the registered spec', () => {
    const def = defineTool<string>({
      name: 'contract_probe',
      description: 'probe carrying every optional field',
      parameters: {},
      output: { schema: {}, render: () => [] },
      timeoutMs: 1,
      deferLoading: true,
      isConcurrencySafe: () => true,
      presentCall: () => ({ card: 'generic', title: 'call' }),
      presentResult: () => ({ card: 'generic', title: 'result' }),
      finalizeContent: () => undefined,
      execute: async () => 'x',
    });
    const spec = toolSpecFrom(def, { plane: 'agent' }) as Record<string, unknown>;
    for (const field of Object.keys(DEFINITION_FIELDS)) {
      if (field === 'execute') continue; // carried as `handler`
      expect(spec[field], `${field} did not reach the spec`).toBeDefined();
    }
    expect(spec.handler, 'execute did not become handler').toBeDefined();
  });

  it('a definition without optional fields stays minimal', () => {
    const def = defineTool<string>({
      name: 'bare_probe',
      description: 'no optional fields',
      parameters: {},
      output: { schema: {}, render: () => [] },
      execute: async () => 'x',
    });
    const spec = toolSpecFrom(def, { plane: 'agent' }) as Record<string, unknown>;
    const required = new Set(['name', 'description', 'parameters', 'output', 'execute']);
    const optional = Object.keys(DEFINITION_FIELDS).filter(f => !required.has(f));
    expect(optional.length).toBeGreaterThan(0);
    for (const field of optional) {
      expect(spec[field], `${field} should be absent`).toBeUndefined();
    }
  });

  it('stagehand tools opt into deferred loading; core tools stay eager', () => {
    // Pins both halves of the contract: the six browser-automation tools ask to
    // be loaded on demand, and enough tools stay eager that the request is legal
    // (DeepSeek rejects "all tools deferred").
    const specs = toToolSpecs();
    const byName = new Map(specs.map(s => [s.name, s]));
    for (const name of [
      'stagehand_navigate', 'stagehand_extract', 'stagehand_screenshot',
      'stagehand_tabs', 'stagehand_observe', 'stagehand_act',
    ]) {
      expect(byName.get(name)?.deferLoading, name).toBe(true);
    }
    expect(byName.get('bash')?.deferLoading).toBeUndefined();
    expect(specs.some(s => s.deferLoading !== true), 'at least one eager tool').toBe(true);
  });
});
