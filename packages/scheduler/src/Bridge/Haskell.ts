// Haskell bridge for trha scheduler
//
// Phase 3 K4: talks to the Haskell kernel's OpenAI-compatible endpoint
// (/v1/chat/completions) instead of the historical, never-wired /api/query.

import { HttpClient } from '../Core/HTTP.js';

export interface BridgeConfig {
  host: string;
  port: number;
}

/** One conversation message: either a legacy [role, content] tuple or a
 * full object (system/user/assistant incl. tool_calls / tool results). */
export type BridgeMessage = [string, string] | Record<string, unknown>;

export interface BridgeToolSpec {
  name: string;
  description: string;
  parameters: Record<string, unknown>;
}

export interface QueryRequest {
  messages: BridgeMessage[];
  tools?: BridgeToolSpec[] | undefined;
  model?: string | undefined;
  /** Which saved provider answers this request (P6). */
  provider?: string | undefined;
  /** Model generation params (LLM settings; absent = kernel defaults). */
  genParams?: { temperature?: number | undefined; topP?: number | undefined; maxTokens?: number | undefined } | undefined;
  /**
   * Kernel session key. When set, the kernel mirrors its D-3 projections
   * (t6state/constraint) and advances its FSM on that session. Absent means
   * the call is served statelessly (plain OpenAI compatibility).
   */
  sessionId?: string | undefined;
}

export interface ToolCallData {
  id: string;
  name: string;
  arguments: string;
}

export interface QueryResponse {
  reply: string;
  /** Thinking-mode chain, echoed back on the next tool turn. */
  reasoningContent?: string;
  toolCalls?: ToolCallData[];
  usage?: {
    promptTokens?: number | undefined;
    completionTokens?: number | undefined;
    totalTokens?: number | undefined;
    cacheHitTokens?: number | undefined;
    cacheMissTokens?: number | undefined;
  };
  /** Kernel's causal-constraint verdict (`trha_constraint`), verbatim object,
   *  when the kernel attaches it to the completion response (D-1). */
  constraint?: Record<string, unknown>;
}

export interface VerifyRequest {
  typeRep: string;
  value: string;
}

export interface VerifyResponse {
  result: boolean;
  error?: string;
}

export class HaskellBridge {
  private httpClient: HttpClient;
  private config: BridgeConfig;

  constructor(config: BridgeConfig) {
    this.config = config;
    this.httpClient = new HttpClient(config.host, config.port);
  }

  /** The kernel's base URL — for calls that need fetch directly (streaming). */
  private baseUrl(): string {
    return `http://${this.config.host}:${this.config.port}`;
  }

  /**
   * Ensure the kernel has a session record for this id. Called on create and
   * again on restore, because a kernel restart may empty its in-memory map —
   * though with a state directory the kernel usually reloads the session from
   * disk first. The endpoint is idempotent: an id the kernel already knows
   * (live or restored) keeps its FSM state, and the reply says
   * `resumed: true` instead of resetting it to Idle.
   */
  async startKernelSession(sessionId: string, mode: string): Promise<void> {
    await this.httpClient.post<Record<string, unknown>>('/session/start', { sessionId, mode });
  }

  /**
   * Drop a session kernel-side. Idempotent. Needed in addition to removing
   * the scheduler's own record: the kernel keeps a snapshot on disk, and an
   * undeleted snapshot brings a deleted conversation back after a restart.
   */
  async deleteKernelSession(sessionId: string): Promise<void> {
    await this.httpClient.delete<Record<string, unknown>>(
      `/session/${encodeURIComponent(sessionId)}`,
    );
  }

  /**
   * Park a command at the kernel's approval gate.
   *
   * From here the kernel holds the session in `awaiting_approval`, which is a
   * real barrier: it refuses steps until the decision arrives, and the parked
   * request survives a kernel restart. The scheduler keeps its own
   * `pendingApproval` for the shell's UX, but the kernel is the gate of record.
   *
   * 409 means the kernel already has a request parked for this session; the
   * caller's own pending state says the same thing, so it is not an error.
   */
  async requestApproval(sessionId: string, message: string, action = 'step'): Promise<void> {
    await this.httpClient.post<Record<string, unknown>>(
      `/session/${encodeURIComponent(sessionId)}/approval`,
      { message, action },
    );
  }

  /** Release the kernel's gate. Idempotent from the caller's view (400 = nothing parked). */
  async decideApproval(sessionId: string, approve: boolean): Promise<void> {
    await this.httpClient.post<Record<string, unknown>>(
      `/session/${encodeURIComponent(sessionId)}/decision`,
      { approve },
    );
  }

  /**
   * Multi-step plans live in the kernel: it holds the phase, the per-step
   * statuses and the barrier, and it persists them. The scheduler only
   * forwards, so there is no second copy of "which step is pending" to drift.
   */
  async submitPlan(sessionId: string, plan: Record<string, unknown>): Promise<Record<string, unknown>> {
    return this.httpClient.post<Record<string, unknown>>(
      `/session/${encodeURIComponent(sessionId)}/plan`,
      plan,
    );
  }

  async getPlan(sessionId: string): Promise<Record<string, unknown>> {
    return this.httpClient.get<Record<string, unknown>>(
      `/session/${encodeURIComponent(sessionId)}/plan`,
    );
  }

  async decidePlan(sessionId: string, action: string): Promise<Record<string, unknown>> {
    return this.httpClient.post<Record<string, unknown>>(
      `/session/${encodeURIComponent(sessionId)}/decision`,
      { action },
    );
  }

  async reportStep(
    sessionId: string, stepId: string, ok: boolean, output?: unknown,
  ): Promise<Record<string, unknown>> {
    return this.httpClient.post<Record<string, unknown>>(
      `/session/${encodeURIComponent(sessionId)}/step-result`,
      output === undefined ? { stepId, ok } : { stepId, ok, output },
    );
  }

  /** Read the kernel's own event log for a session (empty when unreachable). */
  async getSessionEvents(sessionId: string): Promise<Array<Record<string, unknown>>> {
    try {
      const answer = await this.httpClient.get<{ events?: Array<Record<string, unknown>> }>(
        `/session/${encodeURIComponent(sessionId)}/events`,
      );
      return answer.events ?? [];
    } catch {
      // The kernel may be down; an empty log is the honest answer, not an error
      // that breaks the whole tool call.
      return [];
    }
  }

  /** Call the kernel chat completions endpoint (non-streaming). */
  async queryModel(request: QueryRequest): Promise<QueryResponse> {
    const body: Record<string, unknown> = {
      messages: request.messages.map(normalizeMessage),
      stream: false,
    };
    if (request.tools && request.tools.length > 0) {
      body.tools = request.tools.map(t => ({
        type: 'function',
        function: { name: t.name, description: t.description, parameters: t.parameters },
      }));
    }
    if (request.model) body.model = request.model;
    if (request.provider) body.provider = request.provider;
    // LLM 设置 → 内核（temperature/topP/maxTokens；省略 = 内核默认）
    if (request.genParams) {
      if (request.genParams.temperature !== undefined) body.temperature = request.genParams.temperature;
      if (request.genParams.topP !== undefined) body.topP = request.genParams.topP;
      if (request.genParams.maxTokens !== undefined) body.max_tokens = request.genParams.maxTokens;
    }
    if (request.sessionId) body.sessionId = request.sessionId;

    const raw = await this.httpClient.post<Record<string, unknown>>('/v1/chat/completions', body);
    return parseCompletion(raw);
  }

  /** Call the kernel's *streaming* endpoint, handing each text increment to
   * onDelta the moment it arrives (A3).  The reply is their concatenation, so
   * callers that ignore onDelta see exactly what queryModel would return. */
  async queryModelStream(
    request: QueryRequest,
    onDelta: (text: string) => void,
  ): Promise<QueryResponse> {
    const body: Record<string, unknown> = {
      messages: request.messages.map(normalizeMessage),
      stream: true,
    };
    if (request.sessionId) body.sessionId = request.sessionId;
    if (request.tools && request.tools.length > 0) {
      body.tools = request.tools.map(t => ({
        type: 'function',
        function: { name: t.name, description: t.description, parameters: t.parameters },
      }));
    }
    if (request.model) body.model = request.model;
    if (request.provider) body.provider = request.provider;

    const r = await fetch(`${this.baseUrl()}/v1/chat/completions/stream`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Accept: 'text/event-stream' },
      body: JSON.stringify(body),
    });
    const contentType = r.headers.get('content-type') ?? '';
    // A kernel that answers with plain JSON has no streaming endpoint (or the
    // wire could not stream): say so, so the caller can fall back instead of
    // seeing a silently empty reply.
    if (!r.ok || !r.body || !contentType.includes('text/event-stream')) {
      throw new Error(`kernel stream failed: HTTP ${r.status} (${contentType || 'no content-type'})`);
    }

    const reader = r.body.getReader();
    const decoder = new TextDecoder();
    let buf = '';
    let reply = '';
    let reasoning = '';
    let usage: QueryResponse['usage'];
    let constraint: Record<string, unknown> | undefined;
    const calls = new Map<number, ToolCallData>();
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      buf += decoder.decode(value, { stream: true });
      let i = buf.indexOf('\n\n');
      while (i >= 0) {
        const frame = buf.slice(0, i);
        buf = buf.slice(i + 2);
        for (const line of frame.split('\n')) {
          if (!line.startsWith('data: ')) continue;
          const payload = line.slice(6);
          if (payload === '[DONE]') continue;
          let parsed: Record<string, unknown>;
          try { parsed = JSON.parse(payload) as Record<string, unknown>; } catch { continue; }
          // An error frame must fail the call, or the caller would take an
          // empty reply for an answer and never fall back.
          if (parsed.error) {
            const err = parsed.error as { message?: string };
            throw new Error(`kernel stream: ${err.message ?? 'stream error'}`);
          }
          if (typeof parsed.trha_constraint === 'object' && parsed.trha_constraint !== null) {
            constraint = parsed.trha_constraint as Record<string, unknown>;
          }
          // The kernel emits a usage frame at the end; it carries the cache
          // split, which is the only way a streamed call can be billed.
          if (parsed.usage) {
            const u = parsed.usage as Record<string, number>;
            usage = {
              promptTokens: u.prompt_tokens,
              completionTokens: u.completion_tokens,
              totalTokens: u.total_tokens,
              cacheHitTokens: u.prompt_cache_hit_tokens,
              cacheMissTokens: u.prompt_cache_miss_tokens,
            };
          }
          const delta = (parsed.choices as { delta?: {
            content?: string;
            reasoning_content?: string;
            tool_calls?: { index?: number; id?: string; function?: { name?: string; arguments?: string } }[];
          } }[] | undefined)?.[0]?.delta;
          if (!delta) continue;
          if (delta.content) { reply += delta.content; onDelta(delta.content); }
          if (delta.reasoning_content) reasoning += delta.reasoning_content;
          for (const tc of delta.tool_calls ?? []) {
            const idx = tc.index ?? 0;
            const cur = calls.get(idx) ?? { id: '', name: '', arguments: '' };
            if (tc.id) cur.id = tc.id;
            if (tc.function?.name) cur.name += tc.function.name;
            if (tc.function?.arguments) cur.arguments += tc.function.arguments;
            calls.set(idx, cur);
          }
        }
        i = buf.indexOf('\n\n');
      }
    }
    const toolCalls = [...calls.values()].filter(c => c.name !== '');
    const base: QueryResponse = {
      reply,
      ...(reasoning ? { reasoningContent: reasoning } : {}),
      ...(usage ? { usage } : {}),
      ...(toolCalls.length > 0 ? { toolCalls } : {}),
    };
    return constraint ? { ...base, constraint } : base;
  }

  async verifyType(request: VerifyRequest): Promise<VerifyResponse> {
    return this.httpClient.post<VerifyResponse>('/api/verify', request);
  }

  async cacheLookup(key: string): Promise<unknown | null> {
    try {
      return await this.httpClient.get(`/api/cache/${key}`);
    } catch {
      return null;
    }
  }

  async cacheInsert(key: string, value: unknown): Promise<void> {
    await this.httpClient.post('/api/cache', { key, value });
  }
}

function normalizeMessage(m: BridgeMessage): Record<string, unknown> {
  if (Array.isArray(m)) {
    return { role: m[0], content: m[1] ?? '' };
  }
  return m;
}

function parseCompletion(raw: Record<string, unknown>): QueryResponse {
  const choice = (Array.isArray(raw.choices) ? raw.choices[0] : undefined) as
    | { message?: { content?: unknown; tool_calls?: unknown } }
    | undefined;
  const message = choice?.message;
  const content = typeof message?.content === 'string' ? message.content : '';

  let toolCalls: ToolCallData[] | undefined;
  if (Array.isArray(message?.tool_calls)) {
    toolCalls = message.tool_calls
      .map(tc => {
        const o = tc as { id?: unknown; function?: { name?: unknown; arguments?: unknown } };
        return {
          id: String(o.id ?? ''),
          name: String(o.function?.name ?? ''),
          // Accept both shapes: the OpenAI wire says string, but an object
          // comes back from some providers and must not become "[object Object]".
          arguments: typeof o.function?.arguments === 'string'
            ? o.function.arguments
            : JSON.stringify(o.function?.arguments ?? {}),
        };
      })
      .filter(tc => tc.name !== '');
    if (toolCalls.length === 0) toolCalls = undefined;
  }

  const usageRaw = raw.usage as {
    prompt_tokens?: unknown; completion_tokens?: unknown; total_tokens?: unknown;
    prompt_cache_hit_tokens?: unknown; prompt_cache_miss_tokens?: unknown;
  } | undefined;
  const constraint = typeof raw.trha_constraint === 'object' && raw.trha_constraint !== null
    ? (raw.trha_constraint as Record<string, unknown>)
    : undefined;
  return {
    reply: content,
    ...(toolCalls ? { toolCalls } : {}),
    usage: {
      promptTokens: typeof usageRaw?.prompt_tokens === 'number' ? usageRaw.prompt_tokens : undefined,
      completionTokens: typeof usageRaw?.completion_tokens === 'number' ? usageRaw.completion_tokens : undefined,
      totalTokens: typeof usageRaw?.total_tokens === 'number' ? usageRaw.total_tokens : undefined,
      // Cache accounting: without these the bill's biggest lever is invisible.
      cacheHitTokens: typeof usageRaw?.prompt_cache_hit_tokens === 'number'
        ? usageRaw.prompt_cache_hit_tokens : undefined,
      cacheMissTokens: typeof usageRaw?.prompt_cache_miss_tokens === 'number'
        ? usageRaw.prompt_cache_miss_tokens : undefined,
    },
    ...(constraint ? { constraint } : {}),
  };
}
