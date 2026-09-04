// SDK Client for trha

import { SchedulerConfig, defaultConfig, SchedulerError } from './Types.js';
import { HttpClient } from './HTTP.js';

export class SchedulerClient {
  private config: SchedulerConfig;
  private httpClient: HttpClient;

  constructor(config?: Partial<SchedulerConfig>) {
    this.config = { ...defaultConfig, ...config };
    this.httpClient = new HttpClient(this.config.host, this.config.port);
  }

  // Session operations
  async createSession(): Promise<string> {
    const response = await this.httpClient.post<{ id: string }>('/api/sessions', {});
    return response.id;
  }

  async listSessions(): Promise<string[]> {
    const response = await this.httpClient.get<{ sessions: string[] }>('/api/sessions');
    return response.sessions;
  }

  async getSession(sessionId: string): Promise<unknown> {
    return this.httpClient.get(`/api/sessions/${sessionId}`);
  }

  async deleteSession(sessionId: string): Promise<void> {
    await this.httpClient.delete(`/api/sessions/${sessionId}`);
  }

  // Message operations
  async sendMessage(sessionId: string, content: string): Promise<unknown> {
    return this.httpClient.post(`/api/sessions/${sessionId}/messages`, { content });
  }

  async getMessages(sessionId: string): Promise<unknown[]> {
    const response = await this.httpClient.get<{ messages: unknown[] }>(`/api/sessions/${sessionId}/messages`);
    return response.messages;
  }

  // Agent operations
  async getAgentState(agentId: string): Promise<unknown> {
    return this.httpClient.get(`/api/agents/${agentId}`);
  }

  async updateAgentState(agentId: string, state: unknown): Promise<void> {
    await this.httpClient.put(`/api/agents/${agentId}`, state);
  }

  // Tool operations
  async listTools(): Promise<unknown[]> {
    const response = await this.httpClient.get<{ tools: unknown[] }>('/api/tools');
    return response.tools;
  }

  async registerTool(tool: unknown): Promise<void> {
    await this.httpClient.post('/api/tools', tool);
  }

  async unregisterTool(toolName: string): Promise<void> {
    await this.httpClient.delete(`/api/tools/${toolName}`);
  }

  // Model operations
  async listModels(): Promise<unknown[]> {
    const response = await this.httpClient.get<{ models: unknown[] }>('/api/models');
    return response.models;
  }

  async getModel(modelName: string): Promise<unknown> {
    return this.httpClient.get(`/api/models/${modelName}`);
  }

  // Health check
  async healthCheck(): Promise<boolean> {
    const response = await this.httpClient.get<{ status: boolean }>('/api/health');
    return response.status;
  }
}