// Mock Port implementation: in-memory, deterministic, for UI development
// and tests without a scheduler.  Also the consumer proof that the Port
// interface types (T1a) are implementable.

import type { Port, PermissionRuleEntry, StepTarget } from './port.js';
import type {
  DecisionResult,
  PlanAwaiting,
  PortEvent,
  PortModeConfig,
  PortModel,
  PortSession,
  PortSessionMessage,
  PortToolSpec,
  StepResult,
  StudioVersion,
} from './types.js';
import type { Protocol, ProviderCheck, ProviderDraft, ProviderEdit, ProviderEntry, ProviderProbe } from './provider.js';

const MOCK_MODES: Record<string, PortModeConfig> = {
  standard: {
    name: 'standard', description: 'Full agent', tools: ['read_file', 'write_file'],
    persona: { enabled: true, template: '', maxBytes: 1024 },
    compaction: { enabled: true, prunerEnabled: true, thresholdChars: 2000, headChars: 400, tailChars: 200 },
    delegation: { enabled: true, forkEnabled: true, ralphEnabled: false, maxRounds: 4 },
    ptc: { enabled: false, language: '', description: '' },
    hasPlan: true, hasTodo: false, hasWebSearch: false, hasShell: false,
    maxTokens: 2048, contextSize: 8192,
  },
  minimal: {
    name: 'minimal', description: 'Lightweight', tools: ['read_file'],
    persona: { enabled: false, template: '', maxBytes: 0 },
    compaction: { enabled: false, prunerEnabled: false, thresholdChars: 0, headChars: 0, tailChars: 0 },
    delegation: { enabled: false, forkEnabled: false, ralphEnabled: false, maxRounds: 0 },
    ptc: { enabled: false, language: '', description: '' },
    hasPlan: false, hasTodo: false, hasWebSearch: false, hasShell: true,
    maxTokens: 1024, contextSize: 4096,
  },
};

const MOCK_MODELS: PortModel[] = [
  { name: 'mock-model', description: 'Mock model', contextSize: 8192 },
];

const MOCK_TOOLS: PortToolSpec[] = [
  { name: 'read_file', description: 'Read a file', parameters: { type: 'object', properties: { path: { type: 'string' } }, required: ['path'] } },
  { name: 'write_file', description: 'Write a file', parameters: { type: 'object', properties: { path: { type: 'string' }, content: { type: 'string' } }, required: ['path', 'content'] } },
];

let sequence = 0;
const nextId = (): string => `mock-new-${++sequence}`;

/** Same derivation the kernel uses (Core.Provider.Types.providerKeyEnv). */
export function keyEnvFor(name: string): string {
  const body = name.trim().toUpperCase().replace(/[^A-Z0-9]+/g, '_').replace(/^_+/, '');
  const custom = /^[A-Z_]/.test(body) ? '' : 'CUSTOM_';
  return `${custom}${body}_API_KEY`;
}

export class MockPort implements Port {
  private permRules: PermissionRuleEntry[] = [];
  private extraRoots: string[] = [];
  private sessions: Map<string, PortSession> = new Map();
  private listeners: Map<string, Set<(e: PortEvent) => void>> = new Map();
  private providers: ProviderEntry[] = [];
  /** The provider/model the last step was aimed at (P6; test-visible). */
  lastTarget: StepTarget | undefined;

  constructor() {
    const t = new Date().toISOString();
    this.sessions.set('mock-1', {
      id: 'mock-1', mode: 'standard', pendingApproval: null, createdAt: t,
      messages: [
        { role: 'user', content: 'hello from the mock fixture' },
        { role: 'assistant', content: 'mock reply: hello!' },
      ],
    });
    this.sessions.set('mock-2', {
      id: 'mock-2', mode: 'standard', pendingApproval: null, createdAt: t,
      messages: [],
    });
  }

  async modes(): Promise<Record<string, PortModeConfig>> {
    return { ...MOCK_MODES };
  }
  async models(): Promise<PortModel[]> {
    return [...MOCK_MODELS];
  }
  async tools(): Promise<PortToolSpec[]> {
    return [...MOCK_TOOLS];
  }
  async listSessions(): Promise<PortSession[]> {
    return Array.from(this.sessions.values());
  }
  async getSession(id: string): Promise<PortSession> {
    const s = this.sessions.get(id);
    if (!s) throw new Error(`session not found: ${id}`);
    return s;
  }
  async sessionMessages(id: string): Promise<PortSessionMessage[]> {
    return (await this.getSession(id)).messages;
  }
  async createSession(mode: string): Promise<{ sessionId: string; mode: string }> {
    const sessionId = nextId();
    this.sessions.set(sessionId, {
      id: sessionId, mode, pendingApproval: null, createdAt: new Date().toISOString(), messages: [],
    });
    return { sessionId, mode };
  }
  async deleteSession(id: string): Promise<void> {
    this.sessions.delete(id);
  }

  async step(sessionId: string, message: string, requireApproval?: boolean, target?: StepTarget): Promise<StepResult | PlanAwaiting> {
    this.lastTarget = target;
    const session = await this.getSession(sessionId);
    session.messages.push({ role: 'user', content: message });
    this.emit(sessionId, { type: 'message', role: 'user', content: message });
    if (requireApproval) {
      session.pendingApproval = { message };
      this.emit(sessionId, { type: 'plan', status: 'awaiting_approval', message });
      return { status: 'awaiting_approval', pending: { message }, mode: session.mode };
    }
    const reply = `(mock) you said: ${message}`;
    session.messages.push({ role: 'assistant', content: reply });
    this.emit(sessionId, { type: 'message', role: 'assistant', content: reply });
    return { reply, messages: session.messages, mode: session.mode };
  }

  async decision(sessionId: string, approve: boolean): Promise<DecisionResult> {
    const session = await this.getSession(sessionId);
    session.pendingApproval = null;
    this.emit(sessionId, { type: 'decision', status: approve ? 'approved' : 'denied' });
    if (!approve) return { status: 'denied', mode: session.mode };
    const reply = '(mock) plan approved';
    session.messages.push({ role: 'assistant', content: reply });
    return { status: 'approved', reply, messages: session.messages, mode: session.mode };
  }

  subscribe(sessionId: string, onEvent: (e: PortEvent) => void): () => void {
    const set = this.listeners.get(sessionId) ?? new Set();
    set.add(onEvent);
    this.listeners.set(sessionId, set);
    return () => {
      set.delete(onEvent);
      if (set.size === 0) this.listeners.delete(sessionId);
    };
  }

  async studioVersion(): Promise<StudioVersion> {
    return { current: '0.0.0-mock', pinned: null, versions: [{ version: '0.0.0-mock', current: true }] };
  }

  // Provider registry, in memory: enough to exercise the panel offline.
  // Probing a URL answers with a fixed catalogue, so tests are deterministic.
  async providerEntries(): Promise<ProviderEntry[]> {
    return [...this.providers];
  }
  async protocols(): Promise<Protocol[]> {
    return [
      { kind: 'openai', discovery: 'openai', serverWebSearch: true, reasoningParams: true },
      { kind: 'anthropic', discovery: 'anthropic', serverWebSearch: false, reasoningParams: true },
      { kind: 'responses', discovery: 'openai', serverWebSearch: true, reasoningParams: true },
      { kind: 'extension', discovery: 'openai', serverWebSearch: false, reasoningParams: false },
    ];
  }
  async probeProvider(baseUrl: string, _apiKey: string): Promise<ProviderProbe> {
    if (!/^https?:\/\//.test(baseUrl.trim())) {
      throw new Error('provider.unreachable');
    }
    const models = ['mock-model-a', 'mock-model-b'];
    return {
      kind: 'openai', kinds: ['openai', 'responses'], authHeader: true,
      models, default: models[0], efforts: [], effort: '', vision: [],
      ambiguous: false, noProxy: false,
    };
  }
  async saveProvider(draft: ProviderDraft): Promise<ProviderEntry[]> {
    const entry: ProviderEntry = {
      name: draft.name.trim(), kind: draft.kind, baseUrl: draft.baseUrl.trim(),
      models: draft.models, default: draft.default || draft.models[0] || '',
      hasKey: draft.apiKey.trim() !== '', keyEnv: keyEnvFor(draft.name),
      visionModels: draft.vision, preset: false, inUse: false,
    };
    this.providers = [...this.providers.filter(p => p.name !== entry.name), entry];
    return [...this.providers];
  }
  async editProvider(edit: ProviderEdit): Promise<ProviderEntry[]> {
    this.providers = this.providers.map(p => p.name !== edit.name ? p : {
      ...p,
      baseUrl: edit.baseUrl?.trim() || p.baseUrl,
      models: edit.models ?? p.models,
      default: edit.default ?? p.default,
      visionModels: edit.vision ?? p.visionModels,
      hasKey: edit.apiKey && edit.apiKey.trim() !== '' ? true : p.hasKey,
    });
    return [...this.providers];
  }
  async setWebSearch(name: string, on: boolean): Promise<ProviderEntry[]> {
    this.providers = this.providers.map(p => p.name === name ? { ...p, webSearch: on } : p);
    return [...this.providers];
  }
  async setThinking(name: string, on: boolean): Promise<ProviderEntry[]> {
    this.providers = this.providers.map(p => p.name === name ? { ...p, sendsThinking: on } : p);
    return [...this.providers];
  }
  async checkProvider(name: string): Promise<ProviderCheck> {
    const entry = this.providers.find(p => p.name === name);
    if (!entry) return { ok: false, error: `no provider named ${name}`, code: 'provider.not_found' };
    return { ok: true, kind: entry.kind, models: entry.models, ambiguous: false, noProxy: false };
  }
  async permissionRules(): Promise<PermissionRuleEntry[]> {
    return this.permRules;
  }
  async setPermissions(rules: PermissionRuleEntry[]): Promise<PermissionRuleEntry[]> {
    this.permRules = rules;
    return rules;
  }
  async writeRoots(): Promise<string[]> { return this.extraRoots; }
  async setWriteRoots(roots: string[]): Promise<string[]> { this.extraRoots = roots; return roots; }
  async removeProvider(name: string): Promise<ProviderEntry[]> {
    this.providers = this.providers.filter(p => p.name !== name);
    return [...this.providers];
  }

  /** Test/dev helper: push a synthetic event to subscribers. */
  emitMock(sessionId: string, e: PortEvent): void {
    this.emit(sessionId, e);
  }

  private emit(sessionId: string, e: PortEvent): void {
    for (const fn of this.listeners.get(sessionId) ?? []) {
      fn(e);
    }
  }
}
