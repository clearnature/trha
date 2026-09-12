// Provider registry types (mirror of the kernel's shapes in
// src/Core/Provider/Types.hs — the UI must not invent fields).

export interface ProviderEntry {
  name: string;
  kind: string;          // openai | anthropic | responses | extension
  baseUrl: string;
  models: string[];
  default: string;
  hasKey: boolean;
  keyEnv?: string;
  visionModels?: string[];
  preset?: boolean;      // shipped by the kernel, not typed by the user
  inUse?: boolean;
  contextWindow?: number;
  /** Endpoint-executed search / thinking on the wire; absent = not set. */
  webSearch?: boolean | null;
  sendsThinking?: boolean | null;
}

/** A wire format a source may be saved as, as the kernel declares it. */
export interface Protocol {
  kind: string;
  discovery: string;
  serverWebSearch: boolean;
  reasoningParams: boolean;
}

/** What an endpoint turned out to be. Every field is a guess the user confirms. */
export interface ProviderProbe {
  kind: string;
  kinds: string[];
  authHeader: boolean;
  models: string[];
  default: string;
  efforts: string[];
  effort: string;
  vision: string[];
  ambiguous: boolean;
  noProxy: boolean;
}

/** Why a re-probe failed, with the kernel's machine-readable code. */
export interface ProviderCheck {
  ok: boolean;
  kind?: string;
  models?: string[];
  ambiguous?: boolean;
  noProxy?: boolean;
  error?: string;
  code?: string;
}

/** What the panel sends after the user has looked at the probe. */
export interface ProviderDraft {
  name: string;
  kind: string;
  baseUrl: string;
  apiKey: string;
  models: string[];
  default: string;
  authHeader: boolean;
  noProxy: boolean;
  effort: string;
  vision: string[];
}

/** Changing a source that exists: everything omitted stays as it was. */
export interface ProviderEdit {
  name: string;
  baseUrl?: string;
  /** Empty keeps the stored key. */
  apiKey?: string;
  models?: string[];
  default?: string;
  vision?: string[];
}

/** The four wire words the kernel understands, as the panel names them. */
export const KIND_LABEL: Record<string, string> = {
  openai: 'OpenAI 兼容',
  anthropic: 'Anthropic 兼容',
  responses: 'Responses',
  extension: '扩展',
};
