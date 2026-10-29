// HTTP/SSE implementation of the Port surface (SchedulerPort): talks to the
// trha scheduler over its REST + SSE endpoints.  Composed with the pure SSE
// helpers so subscribe() and the CRUD/step calls share one config/token.

import type { MemoryEntry, PermissionRuleEntry, PluginEntry, Port, StepTarget, UsageRow } from './port.js';
import type { ApiConfig } from '../stores/apiConfig.js';
import type {
  DecisionResult,
  PlanAnswer,
  PlanAwaiting,
  PlanDecision,
  PortModeConfig,
  PortModel,
  PortSandboxScope,
  PortSandboxStatus,
  PortSession,
  PortSessionMessage,
  PortToolSpec,
  StepResult,
  StudioVersion,
} from './types.js';
import type { Protocol, ProviderCheck, ProviderDraft, ProviderEdit, ProviderEntry, ProviderProbe } from './provider.js';
import { consumeSse } from './sse.js';

export class SchedulerPort implements Port {
  constructor(
    private readonly cfg: ApiConfig,
    private readonly token = '',
  ) {}

  private headers(extra: Record<string, string> = {}): Record<string, string> {
    const h: Record<string, string> = { 'Content-Type': 'application/json', ...extra };
    if (this.cfg.useToken) h.Authorization = `Bearer ${this.token}`;
    return h;
  }

  private async request<T>(path: string, init?: RequestInit): Promise<T> {
    const merged = {
      ...init,
      headers: { ...this.headers(), ...(init?.headers as Record<string, string> | undefined) },
    };
    const res = await fetch(`${this.cfg.base}${path}`, merged);
    if (!res.ok) {
      throw new Error(`API ${path}: HTTP ${res.status}`);
    }
    return (await res.json()) as T;
  }

  modes(): Promise<Record<string, PortModeConfig>> {
    return this.request('/api/modes');
  }
  models(): Promise<PortModel[]> {
    return this.request('/api/models');
  }
  tools(mode?: string): Promise<PortToolSpec[]> {
    const q = mode ? `?mode=${encodeURIComponent(mode)}` : '';
    return this.request(`/api/tools${q}`);
  }
  listSessions(): Promise<PortSession[]> {
    return this.request('/api/sessions');
  }
  getSession(id: string): Promise<PortSession> {
    return this.request(`/api/session/${encodeURIComponent(id)}`);
  }
  sessionMessages(id: string): Promise<PortSessionMessage[]> {
    return this.request<{ messages: PortSessionMessage[] }>(`/api/session/${encodeURIComponent(id)}/messages`).then(r => r.messages);
  }
  async createSession(mode: string): Promise<{ sessionId: string; mode: string }> {
    return this.request('/api/session/start', {
      method: 'POST',
      headers: this.headers(),
      body: JSON.stringify({ mode }),
    });
  }
  async deleteSession(id: string): Promise<void> {
    await this.request(`/api/session/${encodeURIComponent(id)}`, { method: 'DELETE' });
  }
  step(sessionId: string, message: string, requireApproval?: boolean, target?: StepTarget): Promise<StepResult | PlanAwaiting> {
    return this.request('/api/agent/step', {
      method: 'POST',
      headers: this.headers(),
      body: JSON.stringify({
        sessionId, message, requireApproval,
        provider: target?.provider, model: target?.model,
        temperature: target?.genParams?.temperature,
        topP: target?.genParams?.topP,
        maxTokens: target?.genParams?.maxTokens,
      }),
    });
  }
  decision(sessionId: string, approve: boolean): Promise<DecisionResult> {
    return this.request(`/api/session/${encodeURIComponent(sessionId)}/decision`, {
      method: 'POST',
      headers: this.headers(),
      body: JSON.stringify({ approve }),
    });
  }
  submitPlan(sessionId: string, steps: string[]): Promise<PlanAnswer> {
    return this.request(`/api/session/${encodeURIComponent(sessionId)}/plan`, {
      method: 'POST',
      headers: this.headers(),
      body: JSON.stringify({ mode: 'stepwise', steps: steps.map(title => ({ title })) }),
    });
  }
  getPlan(sessionId: string): Promise<PlanAnswer> {
    return this.request(`/api/session/${encodeURIComponent(sessionId)}/plan`, {
      headers: this.headers(),
    });
  }
  decideStep(sessionId: string, action: PlanDecision): Promise<PlanAnswer> {
    return this.request(`/api/session/${encodeURIComponent(sessionId)}/decision`, {
      method: 'POST',
      headers: this.headers(),
      body: JSON.stringify({ action }),
    });
  }
  reportStep(sessionId: string, stepId: string, ok: boolean, output?: unknown): Promise<PlanAnswer> {
    return this.request(`/api/session/${encodeURIComponent(sessionId)}/step-result`, {
      method: 'POST',
      headers: this.headers(),
      body: JSON.stringify(output === undefined ? { stepId, ok } : { stepId, ok, output }),
    });
  }
  studioVersion(): Promise<StudioVersion> {
    return this.request('/studio/versions');
  }

  // Provider registry: the kernel owns it, the scheduler forwards it.
  providerEntries(): Promise<ProviderEntry[]> {
    return this.request<{ providers: ProviderEntry[] }>('/api/providers').then(r => r.providers ?? []);
  }
  protocols(): Promise<Protocol[]> {
    return this.request('/api/providers/protocols');
  }
  probeProvider(baseUrl: string, apiKey: string): Promise<ProviderProbe> {
    return this.request('/api/providers/probe', {
      method: 'POST', headers: this.headers(),
      body: JSON.stringify({ baseUrl, apiKey }),
    });
  }
  permissionRules(): Promise<PermissionRuleEntry[]> {
    return this.request<{ rules: PermissionRuleEntry[] }>('/api/permissions')
      .then(r => r.rules ?? []);
  }
  setPermissions(rules: PermissionRuleEntry[]): Promise<PermissionRuleEntry[]> {
    return this.request<{ rules: PermissionRuleEntry[] }>('/api/permissions', {
      method: 'PUT', headers: this.headers(), body: JSON.stringify({ rules }),
    }).then(r => r.rules ?? []);
  }
  memories(): Promise<{ items: MemoryEntry[]; stats: { background: number; archived: number; instructionFiles: number } }> {
    return this.request('/api/memory');
  }
  saveMemories(items: MemoryEntry[]): Promise<{ items: MemoryEntry[]; stats: { background: number; archived: number; instructionFiles: number } }> {
    return this.request('/api/memory', { method: 'PUT', headers: this.headers(), body: JSON.stringify({ items }) });
  }
  plugins(): Promise<PluginEntry[]> {
    return this.request<PluginEntry[]>('/api/plugins').then(r => Array.isArray(r) ? r : []);
  }
  hooksConfig(): Promise<{ config: string; path: string }> {
    return this.request('/api/hooks');
  }
  saveHooksConfig(config: string): Promise<{ config: string; path: string }> {
    return this.request('/api/hooks', { method: 'PUT', headers: this.headers(), body: JSON.stringify({ config }) });
  }
  usageStats(): Promise<UsageRow[]> {
    return this.request<{ rows: UsageRow[] }>('/api/usage-stats').then(r => r.rows ?? []);
  }
  writeRoots(): Promise<string[]> {
    return this.request<{ roots: string[] }>('/api/sandbox/write-roots').then(r => r.roots ?? []);
  }
  setWriteRoots(roots: string[]): Promise<string[]> {
    return this.request<{ roots: string[] }>('/api/sandbox/write-roots', {
      method: 'PUT', headers: this.headers(), body: JSON.stringify({ roots }),
    }).then(r => r.roots ?? []);
  }
  sandboxStatus(): Promise<PortSandboxStatus> {
    return this.request<PortSandboxStatus>('/api/sandbox/status');
  }
  sandboxScopes(): Promise<PortSandboxScope[]> {
    return this.request<{ scopes: PortSandboxScope[] }>('/api/sandbox/scopes')
      .then(r => r.scopes ?? []);
  }
  saveProvider(draft: ProviderDraft): Promise<ProviderEntry[]> {
    return this.request<{ providers: ProviderEntry[] }>('/api/providers', {
      method: 'POST', headers: this.headers(), body: JSON.stringify(draft),
    }).then(r => r.providers ?? []);
  }
  editProvider(edit: ProviderEdit): Promise<ProviderEntry[]> {
    return this.request<{ providers: ProviderEntry[] }>('/api/providers/edit', {
      method: 'POST', headers: this.headers(), body: JSON.stringify(edit),
    }).then(r => r.providers ?? []);
  }
  setWebSearch(name: string, on: boolean): Promise<ProviderEntry[]> {
    return this.request<{ providers: ProviderEntry[] }>('/api/providers/websearch', {
      method: 'POST', headers: this.headers(), body: JSON.stringify({ name, on }),
    }).then(r => r.providers ?? []);
  }
  setThinking(name: string, on: boolean): Promise<ProviderEntry[]> {
    return this.request<{ providers: ProviderEntry[] }>('/api/providers/thinking', {
      method: 'POST', headers: this.headers(), body: JSON.stringify({ name, on }),
    }).then(r => r.providers ?? []);
  }
  checkProvider(name: string): Promise<ProviderCheck> {
    return this.request('/api/providers/check', {
      method: 'POST', headers: this.headers(), body: JSON.stringify({ name }),
    });
  }
  removeProvider(name: string): Promise<ProviderEntry[]> {
    return this.request<{ providers: ProviderEntry[] }>('/api/providers/remove', {
      method: 'POST', headers: this.headers(), body: JSON.stringify({ name }),
    }).then(r => r.providers ?? []);
  }

  subscribe(sessionId: string, onEvent: Parameters<Port['subscribe']>[1]): () => void {
    const ctrl = new AbortController();
    const url = `${this.cfg.base}/api/events/${encodeURIComponent(sessionId)}`;
    const headers: Record<string, string> = { Accept: 'text/event-stream' };
    if (this.cfg.useToken) headers.Authorization = `Bearer ${this.token}`;
    void fetch(url, { headers, signal: ctrl.signal })
      .then(res => {
        if (!res.ok) throw new Error(`sse HTTP ${res.status}`);
        return consumeSse(res.body, onEvent, ctrl.signal);
      })
      .catch(e => {
        if (!ctrl.signal.aborted) console.error('sse stream:', e);
      });
    return () => ctrl.abort();
  }
}
