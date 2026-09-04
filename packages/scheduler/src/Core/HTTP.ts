// HTTP Client for trha

import axios, { AxiosInstance, AxiosResponse } from 'axios';
import { SchedulerError } from './Types.js';

export class HttpClient {
  private client: AxiosInstance;
  private baseUrl: string;

  constructor(host: string, port: number) {
    this.baseUrl = `http://${host}:${port}`;
    this.client = axios.create({
      baseURL: this.baseUrl,
      timeout: 30000,
      headers: {
        'Content-Type': 'application/json',
      },
    });
  }

  async get<T>(path: string): Promise<T> {
    try {
      const response: AxiosResponse<T> = await this.client.get(path);
      return response.data;
    } catch (error) {
      throw this.handleError(error);
    }
  }

  async post<T>(path: string, data: unknown): Promise<T> {
    try {
      const response: AxiosResponse<T> = await this.client.post(path, data);
      return response.data;
    } catch (error) {
      throw this.handleError(error);
    }
  }

  async put<T>(path: string, data: unknown): Promise<T> {
    try {
      const response: AxiosResponse<T> = await this.client.put(path, data);
      return response.data;
    } catch (error) {
      throw this.handleError(error);
    }
  }

  async delete<T>(path: string): Promise<T> {
    try {
      const response: AxiosResponse<T> = await this.client.delete(path);
      return response.data;
    } catch (error) {
      throw this.handleError(error);
    }
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