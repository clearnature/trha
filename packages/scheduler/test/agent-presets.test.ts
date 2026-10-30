import { describe, expect, it } from 'vitest';
import {
  AGENT_PRESETS,
  DEFAULT_AGENT_PRESET,
  getAgentPreset,
  listAgentPresets,
} from '../src/Server/agentPresets.js';
import { toolCatalog } from '../src/Server/toolCatalog.js';

describe('agent presets', () => {
  it('exposes exactly the four presets Desktop ships', () => {
    expect(Object.keys(AGENT_PRESETS).sort()).toEqual(['cordis', 'minimal', 'ptc', 'standard']);
    expect(listAgentPresets()).toHaveLength(4);
  });

  it('standard is the default and carries the full tool set', () => {
    expect(DEFAULT_AGENT_PRESET).toBe('standard');
    const p = AGENT_PRESETS.standard!;
    expect(p.hasPlan).toBe(true);
    expect(p.hasTodo).toBe(true);
    expect(p.hasWebSearch).toBe(true);
    expect(p.tools).toContain('subagent');
    expect(p.tools).toContain('exit_plan_mode');
  });

  it('ptc swaps plan/todo for run_code', () => {
    const p = AGENT_PRESETS.ptc!;
    expect(p.ptc).toEqual({ enabled: true, language: 'typescript' });
    expect(p.tools).toContain('run_code');
    expect(p.tools).not.toContain('exit_plan_mode');
    expect(p.hasPlan).toBe(false);
    expect(p.hasTodo).toBe(false);
  });

  it('minimal drops web, subagents and compaction', () => {
    const p = AGENT_PRESETS.minimal!;
    expect(p.hasWebSearch).toBe(false);
    expect(p.compaction.enabled).toBe(false);
    expect(p.delegation.enabled).toBe(false);
    expect(p.tools).not.toContain('subagent');
    expect(p.tools).not.toContain('web_search');
  });

  it('cordis ships no tools of its own', () => {
    expect(AGENT_PRESETS.cordis!.tools).toEqual([]);
  });

  it('unknown ids resolve to undefined instead of guessing', () => {
    expect(getAgentPreset('nope')).toBeUndefined();
    expect(getAgentPreset(undefined)).toBeUndefined();
    expect(getAgentPreset('standard')?.name).toBe('standard');
  });

  it('every preset tool name exists in the catalog', () => {
    // These lists shipped stale for a while: `todo`/`plan`/`ask_user` had been
    // renamed, and `subagent_fork`/`checkpoint`/`memory` never existed. Nothing
    // broke because mounting goes through `toolNamesForPreset`, but
    // `/api/agent/presets` handed callers names they could not resolve.
    const catalog = new Set(toolCatalog.map(t => t.name));
    for (const preset of listAgentPresets()) {
      for (const name of preset.tools) {
        expect(catalog.has(name), `${preset.name} → ${name}`).toBe(true);
      }
    }
  });
});
