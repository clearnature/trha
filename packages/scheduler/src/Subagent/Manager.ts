// Subagent manager for gh-harness

export interface SubAgentConfig {
  model: string;
  tools: string[];
  timeout: number;
}

export interface SubAgent {
  id: string;
  config: SubAgentConfig;
  state: 'idle' | 'running' | 'completed' | 'error';
  result?: unknown;
  error?: string;
}

export class SubAgentManager {
  private agents: Map<string, SubAgent> = new Map();

  async spawn(config: SubAgentConfig): Promise<SubAgent> {
    const id = `subagent-${Date.now()}-${Math.random().toString(36).substr(2, 9)}`;
    const agent: SubAgent = {
      id,
      config,
      state: 'idle',
    };

    this.agents.set(id, agent);
    return agent;
  }

  async terminate(id: string): Promise<void> {
    const agent = this.agents.get(id);
    if (!agent) {
      throw new Error(`SubAgent ${id} not found`);
    }

    this.agents.delete(id);
  }

  async getAgent(id: string): Promise<SubAgent | undefined> {
    return this.agents.get(id);
  }

  async listAgents(): Promise<SubAgent[]> {
    return Array.from(this.agents.values());
  }

  async updateState(id: string, state: SubAgent['state'], result?: unknown, error?: string): Promise<void> {
    const agent = this.agents.get(id);
    if (!agent) {
      throw new Error(`SubAgent ${id} not found`);
    }

    agent.state = state;
    if (result !== undefined) {
      agent.result = result;
    }
    if (error !== undefined) {
      agent.error = error;
    }
  }
}