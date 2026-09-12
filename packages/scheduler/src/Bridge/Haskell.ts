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
  tools?: BridgeToolSpec[];
  model?: string;
  /** Which saved provider answers this request (P6). */
  provider?: string;
}

export interface ToolCallData {
  id: string;
  name: string;
  arguments: string;
}

export interface QueryResponse {
  reply: string;
  toolCalls?: ToolCallData[];
  usage?: { promptTokens?: number; completionTokens?: number; totalTokens?: number };
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
          const delta = (parsed.choices as { delta?: {
            content?: string;
            tool_calls?: { index?: number; id?: string; function?: { name?: string; arguments?: string } }[];
          } }[] | undefined)?.[0]?.delta;
          if (!delta) continue;
          if (delta.content) { reply += delta.content; onDelta(delta.content); }
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
    return toolCalls.length > 0 ? { reply, toolCalls } : { reply };
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
          arguments: String(o.function?.arguments ?? ''),
        };
      })
      .filter(tc => tc.name !== '');
    if (toolCalls.length === 0) toolCalls = undefined;
  }

  const usageRaw = raw.usage as { prompt_tokens?: unknown; completion_tokens?: unknown; total_tokens?: unknown } | undefined;
  return {
    reply: content,
    ...(toolCalls ? { toolCalls } : {}),
    usage: {
      promptTokens: typeof usageRaw?.prompt_tokens === 'number' ? usageRaw.prompt_tokens : undefined,
      completionTokens: typeof usageRaw?.completion_tokens === 'number' ? usageRaw.completion_tokens : undefined,
      totalTokens: typeof usageRaw?.total_tokens === 'number' ? usageRaw.total_tokens : undefined,
    },
  };
}
