import { beforeEach, describe, expect, it } from 'vitest';
import {
  listTools,
  registerTool,
  resetToolRegistry,
  resolveTool,
  toolNamesForPreset,
} from '../src/Server/toolRegistry.js';

const ok = async (): Promise<string> => 'ok';

describe('tool registry', () => {
  beforeEach(() => resetToolRegistry());

  it('registers and resolves a tool', () => {
    registerTool({ name: 'web_fetch', plane: 'agent', handler: ok });
    expect(resolveTool('web_fetch')?.name).toBe('web_fetch');
    expect(resolveTool('nope')).toBeUndefined();
  });

  it('refuses duplicate names instead of silently overriding', () => {
    registerTool({ name: 'web_fetch', plane: 'agent', handler: ok });
    expect(() => registerTool({ name: 'web_fetch', plane: 'agent', handler: ok }))
      .toThrow(/already registered/);
  });

  it('keeps host-plane and agent-plane separate', () => {
    registerTool({ name: 'subagents', plane: 'host', handler: ok });
    registerTool({ name: 'bash', plane: 'agent', handler: ok });
    const planes = Object.fromEntries(listTools().map(t => [t.name, t.plane]));
    expect(planes).toEqual({ subagents: 'host', bash: 'agent' });
  });

  it('exposes a tool to every preset when it names none', () => {
    registerTool({ name: 'bash', plane: 'agent', handler: ok });
    expect(toolNamesForPreset('minimal').has('bash')).toBe(true);
    expect(toolNamesForPreset('cordis').has('bash')).toBe(true);
  });

  it('hides a preset-scoped tool from other presets', () => {
    registerTool({ name: 'run_code', plane: 'agent', presets: ['ptc'], handler: ok });
    expect(toolNamesForPreset('ptc').has('run_code')).toBe(true);
    expect(toolNamesForPreset('minimal').has('run_code')).toBe(false);
    // No preset given = pre-migration behaviour: everything registered.
    expect(toolNamesForPreset(undefined).has('run_code')).toBe(true);
  });

  it('filters listTools the same way as the name set', () => {
    registerTool({ name: 'bash', plane: 'agent', handler: ok });
    registerTool({ name: 'run_code', plane: 'agent', presets: ['ptc'], handler: ok });
    expect(listTools('minimal').map(t => t.name)).toEqual(['bash']);
    expect(listTools('ptc').map(t => t.name).sort()).toEqual(['bash', 'run_code']);
  });
});
