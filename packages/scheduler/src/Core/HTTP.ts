// HTTP Client for trha

import axios, { AxiosInstance, AxiosResponse } from 'axios';
import { SchedulerError } from './Types.js';

export class HttpClient {
  private client: AxiosInstance;
  private baseUrl: string;
  private tokenProvider: (() => string | null) | undefined;

  constructor(host: string, port: number, tokenProvider?: () => string | null) {
    this.baseUrl = `http://${host}:${port}`;
    this.tokenProvider = tokenProvider;
    this.client = axios.create({
      baseURL: this.baseUrl,
      timeout: 300000,
      headers: {
        'Content-Type': 'application/json',
      },
    });
  }

  /** Resolved per request: the kernel may mint its token after we boot. */
  private authHeaders(): Record<string, string> {
    const token = this.tokenProvider?.() ?? null;
    return token ? { Authorization: `Bearer ${token}` } : {};
  }

  /**
   * One request, with the kernel's restart handshake: every kernel launch
   * rotates `~/.trha/kernel-token`, so a 401 means "we sent the previous
   * launch's token" — re-read and retry once before giving up.
   */
  private async send<T>(
    fn: (headers: Record<string, string>) => Promise<AxiosResponse<T>>,
  ): Promise<T> {
    try {
      return (await fn(this.authHeaders())).data;
    } catch (error) {
      if (axios.isAxiosError(error) && error.response?.status === 401) {
        try {
          return (await fn(this.authHeaders())).data;
        } catch (retryError) {
          throw this.handleError(retryError);
        }
      }
      throw this.handleError(error);
    }
  }

  async get<T>(path: string): Promise<T> {
    return this.send(h => this.client.get(path, { headers: h }));
  }

  async post<T>(path: string, data: unknown): Promise<T> {
    return this.send(h => this.client.post(path, data, { headers: h }));
  }

  async put<T>(path: string, data: unknown): Promise<T> {
    return this.send(h => this.client.put(path, data, { headers: h }));
  }

  async delete<T>(path: string): Promise<T> {
    return this.send(h => this.client.delete(path, { headers: h }));
  }

  private handleError(error: unknown): SchedulerError {
    if (axios.isAxiosError(error)) {
      if (error.response) {
        const status = error.response.status;
        const message = error.response.data?.message || error.message;

        if (status === 401 || status === 403) {
          return { type: 'authentication', message };
        }

        if (status >= 400 && status < 500) {
          return { type: 'validation', message };
        }

        if (status >= 500) {
          return { type: 'server', message };
        }
      }

      if (error.code === 'ECONNABORTED') {
        return { type: 'timeout' };
      }

      if (error.code === 'ECONNREFUSED' || error.code === 'ENOTFOUND') {
        return { type: 'connection', message: error.message };
      }
    }

    return {
      type: 'unknown',
      message: error instanceof Error ? error.message : String(error),
    };
  }
}