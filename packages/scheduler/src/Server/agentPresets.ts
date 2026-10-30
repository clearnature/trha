/**
 * Agent presets — the shared definition of what each preset enables.
 *
 * These lived only in `packages/app/Desktop/src/renderer/stores/appStore.ts`,
 * so the TUI and the scheduler could not see them: `trha --agent-preset ptc`
 * changed a label and nothing else. Moving the definition here makes it the
 * single source that every shell and the scheduler read.
 */

export interface AgentPreset {
  name: string;
  description: string;
  tools: string[];
  /** DSH's `persona` plugin: `prefix` is the system-prompt lead-in. */
  persona: { enabled: boolean; prefix?: string; maxBytes: number };
  compaction: {
    enabled: boolean;
    prunerEnabled: boolean;
    thresholdChars: number;
    headChars: number;
    tailChars: number;
  };
  delegation: { enabled: boolean; forkEnabled: boolean; ralphEnabled: boolean; maxRounds: number };
  ptc: { enabled: boolean; language: string };
  hasPlan: boolean;
  hasTodo: boolean;
  hasWebSearch: boolean;
  hasShell: boolean;
  maxTokens: number;
  contextSize: number;
}

/** Tool sets are ordered as in `standard`; presets add or drop from there. */
const STANDARD_TOOLS = [
  'bash', 'read', 'write', 'grep', 'glob', 'edit', 'web_search',
  'subagent', 'subagent_fork', 'workflow', 'todo', 'plan', 'ask_user',
  'skill', 'checkpoint', 'memory',
];

export const AGENT_PRESETS: Record<string, AgentPreset> = {
  standard: {
    name: 'standard',
    description: 'Full coding agent',
    tools: STANDARD_TOOLS,
    persona: {
      enabled: true,
      prefix: 'You are a coding agent powered by the {{model}} model.',
      maxBytes: 65536,
    },
    compaction: { enabled: true, prunerEnabled: true, thresholdChars: 8192, headChars: 4096, tailChars: 1024 },
    delegation: { enabled: true, forkEnabled: true, ralphEnabled: true, maxRounds: 64 },
    ptc: { enabled: false, language: '' },
    hasPlan: true,
    hasTodo: true,
    hasWebSearch: true,
    hasShell: true,
    maxTokens: 8192,
    contextSize: 131072,
  },

  ptc: {
    name: 'ptc',
    description: 'Program-the-code',
    // run_code replaces plan/todo/workflow: the model writes a program instead
    // of orchestrating many tool calls.
    tools: ['bash', 'read', 'write', 'grep', 'glob', 'edit', 'web_search',
      'subagent', 'subagent_fork', 'run_code', 'ask_user', 'skill', 'checkpoint', 'memory'],
    persona: {
      enabled: true,
      prefix: 'You are a coding agent powered by the {{model}} model.',
      maxBytes: 65536,
    },
    compaction: { enabled: true, prunerEnabled: true, thresholdChars: 8192, headChars: 4096, tailChars: 1024 },
    delegation: { enabled: true, forkEnabled: true, ralphEnabled: true, maxRounds: 64 },
    ptc: { enabled: true, language: 'typescript' },
    hasPlan: false,
    hasTodo: false,
    hasWebSearch: true,
    hasShell: true,
    maxTokens: 16384,
    contextSize: 131072,
  },

  minimal: {
    name: 'minimal',
    description: 'Lightweight',
    // No subagents, no web, no compaction: the smallest environment in which a
    // mechanism can be observed in isolation (the base `dsh-sol-pi` copies this).
    tools: ['bash', 'read', 'write', 'grep', 'glob', 'edit', 'ask_user'],
    persona: {
      enabled: true,
      prefix: 'You are a helpful software engineer assistant.',
      maxBytes: 65536,
    },
    compaction: { enabled: false, prunerEnabled: false, thresholdChars: 0, headChars: 0, tailChars: 0 },
    delegation: { enabled: false, forkEnabled: false, ralphEnabled: false, maxRounds: 0 },
    ptc: { enabled: false, language: '' },
    hasPlan: false,
    hasTodo: false,
    hasWebSearch: false,
    hasShell: true,
    maxTokens: 4096,
    contextSize: 65536,
  },

  cordis: {
    name: 'cordis',
    description: 'Base layer',
    // No tools at all: everything is supplied by plugins, so the preset defines
    // only the surrounding machinery.
    tools: [],
    persona: {
      enabled: true,
      prefix: 'You are a coding agent powered by the {{model}} model.',
      maxBytes: 65536,
    },
    compaction: { enabled: true, prunerEnabled: true, thresholdChars: 8192, headChars: 4096, tailChars: 1024 },
    delegation: { enabled: true, forkEnabled: true, ralphEnabled: true, maxRounds: 64 },
    ptc: { enabled: false, language: '' },
    hasPlan: false,
    hasTodo: false,
    hasWebSearch: false,
    hasShell: true,
    maxTokens: 4096,
    contextSize: 65536,
  },
};

export const DEFAULT_AGENT_PRESET = 'standard';

export function listAgentPresets(): AgentPreset[] {
  return Object.values(AGENT_PRESETS);
}

/** Unknown ids resolve to `undefined` — callers decide whether to fall back. */
export function getAgentPreset(id: string | undefined): AgentPreset | undefined {
  if (id === undefined) return undefined;
  return AGENT_PRESETS[id];
}
