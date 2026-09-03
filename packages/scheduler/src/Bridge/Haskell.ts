// Haskell bridge for gh-harness scheduler

import { HttpClient } from '../Core/HTTP.js';

export interface BridgeConfig {
  host: string;
  port: number;
}

export interface QueryRequest {
  messages: [string, string][];
}

export interface QueryResponse {
  chunks: string[];
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

  constructor(config: BridgeConfig) {
    this.httpClient = new HttpClient(config.host, config.port);
  }

  async queryModel(request: QueryRequest): Promise<QueryResponse> {
    return this.httpClient.post<QueryResponse>('/api/query', request);
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