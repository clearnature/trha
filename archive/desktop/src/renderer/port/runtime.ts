// Runtime API configuration holder: the Electron shell / studio page
// calls setApiRuntime once (from appStore.initAPI / bootstrap); the port
// assembly reads it.  Kept separate from appStore so port consumers never
// depend on a store module.

import type { ApiConfig } from '../stores/apiConfig.js';

export interface ApiRuntime {
  cfg: ApiConfig;
  token: string;
}

let current: ApiRuntime | null = null;

export function setApiRuntime(cfg: ApiConfig, token: string): void {
  current = { cfg, token };
}

export function getApiRuntime(): ApiRuntime | null {
  return current;
}

export function clearApiRuntime(): void {
  current = null;
}
