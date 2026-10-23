// Subagent Manager - Phase 6: 多 Agent 协作系统

import { EventEmitter } from '../../Utils/EventEmitter.js';
import { Queue } from '../../Utils/Queue.js';
import { createLogger } from '../../Core/Logger.js';
import { withRetry } from '../../Core/Retry.js';

// Types
export interface SubAgentConfig {
  id: string;
  model: string;
  tools: string[];
  timeout: number;
  maxRetries: number;
  parentSessionId: string;
}

export interface SubAgentState {
  id: string;
  config: SubAgentConfig;
  status: 'idle' | 'running' | 'completed' | 'failed' | 'terminated';
  result?: unknown;
  error?: string;
  attempts: number;
  startTime?: Date;
  endTime?: Date;
}

export interface SubAgentTask {
  id: string;
  subagentId: string;
  input: unknown;
  status: 'pending' | 'running' | 'completed' | 'failed';
  result?: unknown;
  error?: string;
}

export interface ManagerConfig {
  maxConcurrent: number;
  defaultTimeout: number;
  defaultMaxRetries: number;
  poolSize: number;
}

// Main Manager Class
export class SubAgentManager {
  private agents: Map<string, SubAgentState> = new Map();
  private tasks: Map<string, SubAgentTask> = new Map();
  private eventEmitter: EventEmitter;
  private logger = createLogger('info', 'SubAgentManager');
  private config: ManagerConfig;
  private taskQueue: Queue<SubAgentTask> = new Queue();
  private runningTasks: Set<string> = new Set();

  constructor(config: ManagerConfig) {
    this.config = config;
    this.eventEmitter = new EventEmitter();
  }

  // Spawn a new subagent
  async spawn(config: Omit<SubAgentConfig, 'id'>): Promise<SubAgentState> {
    const id = `subagent-${Date.now()}-${Math.random().toString(36).substr(2, 9)}`;
    const subagentConfig: SubAgentConfig = { ...config, id };

    const state: SubAgentState = {
      id,
      config: subagentConfig,
      status: 'idle',
      attempts: 0,
    };

    this.agents.set(id, state);
    this.logger.info(`Spawned subagent ${id}`);

    await this.eventEmitter.emit('subagent:spawned', { id, config: subagentConfig });

    return state;
  }

  // Submit a task to a subagent
  async submitTask(subagentId: string, input: unknown): Promise<SubAgentTask> {
    const agent = this.agents.get(subagentId);
    if (!agent) {
      throw new Error(`SubAgent ${subagentId} not found`);
    }

    const taskId = `task-${Date.now()}-${Math.random().toString(36).substr(2, 9)}`;
    const task: SubAgentTask = {
      id: taskId,
      subagentId,
      input,
      status: 'pending',
    };

    this.tasks.set(taskId, task);
    this.taskQueue.enqueue(task);

    this.logger.info(`Submitted task ${taskId} to subagent ${subagentId}`);
    await this.eventEmitter.emit('task:submitted', { taskId, subagentId });

    // Process queue
    this.processQueue();

    return task;
  }

  // Process the task queue
  private async processQueue(): Promise<void> {
    while (
      !this.taskQueue.isEmpty &&
      this.runningTasks.size < this.config.maxConcurrent
    ) {
      const task = this.taskQueue.dequeue();
      if (task) {
        this.executeTask(task);
      }
    }
  }

  // Execute a task with retry logic
  private async executeTask(task: SubAgentTask): Promise<void> {
    const agent = this.agents.get(task.subagentId);
    if (!agent) {
      this.logger.error(`SubAgent ${task.subagentId} not found for task ${task.id}`);
      return;
    }

    this.runningTasks.add(task.id);
    task.status = 'running';
    agent.status = 'running';
    agent.startTime = new Date();

    this.logger.info(`Executing task ${task.id} on subagent ${task.subagentId}`);
    await this.eventEmitter.emit('task:started', { taskId: task.id, subagentId: task.subagentId });

    try {
      const result = await withRetry(
        async () => {
          // Simulate task execution
          // In real implementation, this would call the subagent's execution logic
          return this.simulateExecution(task, agent);
        },
        {
          maxAttempts: agent.config.maxRetries,
          delay: 1000,
          backoff: 2.0,
        }
      );

      task.result = result;
      task.status = 'completed';
      agent.status = 'completed';
      agent.result = result;
      agent.endTime = new Date();

      this.logger.info(`Task ${task.id} completed successfully`);
      await this.eventEmitter.emit('task:completed', { taskId: task.id, result });
    } catch (error) {
      task.status = 'failed';
      task.error = error instanceof Error ? error.message : String(error);
      agent.status = 'failed';
      agent.error = task.error;
      agent.endTime = new Date();

      this.logger.error(`Task ${task.id} failed: ${task.error}`);
      await this.eventEmitter.emit('task:failed', { taskId: task.id, error: task.error });
    } finally {
      this.runningTasks.delete(task.id);
      agent.attempts++;

      // Process next task in queue
      this.processQueue();
    }
  }

  // Simulate task execution (placeholder)
  private async simulateExecution(task: SubAgentTask, agent: SubAgentState): Promise<unknown> {
    // Simulate some work
    await new Promise((resolve) => setTimeout(resolve, 100));

    // Simulate success or failure based on random chance
    if (Math.random() > 0.8) {
      throw new Error('Simulated failure');
    }

    return { result: `Task ${task.id} completed by subagent ${agent.id}` };
  }

  // Get subagent state
  async getAgent(id: string): Promise<SubAgentState | undefined> {
    return this.agents.get(id);
  }

  // List all subagents
  async listAgents(): Promise<SubAgentState[]> {
    return Array.from(this.agents.values());
  }

  // Get task state
  async getTask(taskId: string): Promise<SubAgentTask | undefined> {
    return this.tasks.get(taskId);
  }

  // List all tasks
  async listTasks(): Promise<SubAgentTask[]> {
    return Array.from(this.tasks.values());
  }

  // Terminate a subagent
  async terminate(id: string): Promise<void> {
    const agent = this.agents.get(id);
    if (!agent) {
      throw new Error(`SubAgent ${id} not found`);
    }

    agent.status = 'terminated';
    agent.endTime = new Date();
    this.agents.delete(id);

    this.logger.info(`Terminated subagent ${id}`);
    await this.eventEmitter.emit('subagent:terminated', { id });
  }

  // Update subagent state
  async updateState(id: string, status: SubAgentState['status'], result?: unknown, error?: string): Promise<void> {
    const agent = this.agents.get(id);
    if (!agent) {
      throw new Error(`SubAgent ${id} not found`);
    }

    agent.status = status;
    if (result !== undefined) {
      agent.result = result;
    }
    if (error !== undefined) {
      agent.error = error;
    }
  }

  // Get summary of all subagent results
  async getSummary(): Promise<{
    total: number;
    completed: number;
    failed: number;
    running: number;
    results: Array<{ id: string; status: string; result?: unknown; error?: string | undefined }>;
  }> {
    const agents = Array.from(this.agents.values());

    return {
      total: agents.length,
      completed: agents.filter((a) => a.status === 'completed').length,
      failed: agents.filter((a) => a.status === 'failed').length,
      running: agents.filter((a) => a.status === 'running').length,
      results: agents.map((a) => ({
        id: a.id,
        status: a.status,
        result: a.result,
        error: a.error,
      })),
    };
  }

  // Event listeners
  on(event: string, handler: (...args: unknown[]) => void | Promise<void>): void {
    this.eventEmitter.on(event, handler);
  }

  off(event: string, handler: (...args: unknown[]) => void | Promise<void>): void {
    this.eventEmitter.off(event, handler);
  }
}