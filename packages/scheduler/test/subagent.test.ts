// Tests for Subagent System - Phase 6

import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import {
  SubAgentManager,
  ProtocolHandler,
  SessionManager,
  ErrorHandler,
  ResourcePool,
} from '../src/Subagent/index.js';

describe('Subagent Manager', () => {
  let manager: SubAgentManager;

  beforeEach(() => {
    manager = new SubAgentManager({
      maxConcurrent: 3,
      defaultTimeout: 30000,
      defaultMaxRetries: 3,
      poolSize: 10,
    });
  });

  it('should spawn subagents', async () => {
    const agent = await manager.spawn({
      model: 'deepseek-chat',
      tools: ['read_file'],
      timeout: 30000,
      maxRetries: 3,
      parentSessionId: 'parent-1',
    });

    expect(agent.id).toBeDefined();
    expect(agent.status).toBe('idle');
    expect(agent.config.model).toBe('deepseek-chat');
  });

  it('should submit tasks to subagents', async () => {
    const agent = await manager.spawn({
      model: 'deepseek-chat',
      tools: ['read_file'],
      timeout: 30000,
      maxRetries: 3,
      parentSessionId: 'parent-1',
    });

    const task = await manager.submitTask(agent.id, { input: 'test' });

    expect(task.id).toBeDefined();
    expect(task.subagentId).toBe(agent.id);
    // Task might be running immediately due to async execution
    expect(['pending', 'running']).toContain(task.status);
  });

  it('should get summary', async () => {
    await manager.spawn({
      model: 'deepseek-chat',
      tools: ['read_file'],
      timeout: 30000,
      maxRetries: 3,
      parentSessionId: 'parent-1',
    });

    const summary = await manager.getSummary();
    expect(summary.total).toBe(1);
    expect(summary.completed).toBe(0);
  });
});

describe('Protocol Handler', () => {
  let handler: ProtocolHandler;

  beforeEach(() => {
    handler = new ProtocolHandler();
  });

  it('should create request messages', () => {
    const message = handler.createRequest('agent-1', 'agent-2', 'execute', { input: 'test' });

    expect(message.type).toBe('request');
    expect(message.from).toBe('agent-1');
    expect(message.to).toBe('agent-2');
    expect(message.method).toBe('execute');
  });

  it('should create response messages', () => {
    const message = handler.createResponse('agent-2', 'agent-1', 'req-1', { result: 'success' });

    expect(message.type).toBe('response');
    expect(message.requestId).toBe('req-1');
    expect(message.result).toEqual({ result: 'success' });
  });

  it('should handle requests', async () => {
    let handled = false;

    handler.registerHandler('test', async (message) => {
      handled = true;
      return { success: true };
    });

    const request = handler.createRequest('agent-1', 'agent-2', 'test', {});
    await handler.handleMessage(request);

    expect(handled).toBe(true);
  });
});

describe('Session Manager', () => {
  let manager: SessionManager;

  beforeEach(() => {
    manager = new SessionManager();
  });

  it('should create sessions', async () => {
    const session = await manager.createSession('subagent-1', 'parent-1');

    expect(session.id).toBeDefined();
    expect(session.subagentId).toBe('subagent-1');
    expect(session.parentSessionId).toBe('parent-1');
    expect(session.status).toBe('active');
  });

  it('should add messages', async () => {
    const session = await manager.createSession('subagent-1', 'parent-1');
    const message = await manager.addMessage(session.id, 'user', 'Hello');

    expect(message.role).toBe('user');
    expect(message.content).toBe('Hello');

    const messages = await manager.getMessages(session.id);
    expect(messages).toHaveLength(1);
  });

  it('should complete sessions', async () => {
    const session = await manager.createSession('subagent-1', 'parent-1');
    await manager.completeSession(session.id, 'completed');

    const updated = await manager.getSession(session.id);
    expect(updated?.status).toBe('completed');
    expect(updated?.endTime).toBeDefined();
  });

  it('should get session summary', async () => {
    const session = await manager.createSession('subagent-1', 'parent-1');
    await manager.addMessage(session.id, 'user', 'Hello');
    await manager.addMessage(session.id, 'assistant', 'Hi there!');

    const summary = await manager.getSessionSummary(session.id);

    expect(summary.id).toBe(session.id);
    expect(summary.messageCount).toBe(2);
  });
});

describe('Error Handler', () => {
  let handler: ErrorHandler;

  beforeEach(() => {
    handler = new ErrorHandler({
      maxRetries: 3,
      retryDelay: 1000,
      retryBackoff: 2.0,
      logErrors: false,
    });
  });

  it('should classify timeout errors', async () => {
    const error = new Error('Connection timeout');
    const result = await handler.handleError(error, { subagentId: 'agent-1' });

    expect(result.type).toBe('timeout');
    expect(result.retryable).toBe(true);
  });

  it('should classify connection errors', async () => {
    const error = new Error('ECONNREFUSED');
    const result = await handler.handleError(error, { subagentId: 'agent-1' });

    expect(result.type).toBe('connection');
    expect(result.retryable).toBe(true);
  });

  it('should classify validation errors', async () => {
    const error = new Error('validation failed');
    const result = await handler.handleError(error, { subagentId: 'agent-1' });

    expect(result.type).toBe('validation');
    expect(result.retryable).toBe(false);
  });

  it('should provide retry delay', () => {
    const delay1 = handler.getRetryDelay(1);
    const delay2 = handler.getRetryDelay(2);
    const delay3 = handler.getRetryDelay(3);

    expect(delay1).toBe(1000);
    expect(delay2).toBe(2000);
    expect(delay3).toBe(4000);
  });

  it('should track statistics', async () => {
    await handler.handleError(new Error('timeout'), {});
    await handler.handleError(new Error('ECONNREFUSED'), {});
    await handler.handleError(new Error('validation failed'), {});

    const stats = handler.getStatistics();

    expect(stats.total).toBe(3);
    expect(stats.byType.timeout).toBe(1);
    expect(stats.byType.connection).toBe(1);
    expect(stats.byType.validation).toBe(1);
    expect(stats.retryable).toBe(2);
    expect(stats.nonRetryable).toBe(1);
  });
});

describe('Resource Pool', () => {
  let pool: ResourcePool;

  beforeEach(async () => {
    pool = new ResourcePool({
      maxSize: 5,
      minSize: 2,
      acquireTimeout: 5000,
      idleTimeout: 60000,
      maxRetries: 3,
    });

    await pool.initialize([
      { id: 'resource-1', type: 'cpu', metadata: {} },
      { id: 'resource-2', type: 'cpu', metadata: {} },
      { id: 'resource-3', type: 'gpu', metadata: {} },
    ]);
  });

  it('should acquire resources', async () => {
    const resource = await pool.acquire('cpu');

    expect(resource.id).toBeDefined();
    expect(resource.type).toBe('cpu');
    expect(resource.status).toBe('in-use');
  });

  it('should release resources', async () => {
    const resource = await pool.acquire('cpu');
    await pool.release(resource.id);

    const stats = pool.getStatistics();
    expect(stats.available).toBe(3);
  });

  it('should track statistics', async () => {
    const stats = pool.getStatistics();

    expect(stats.total).toBe(3);
    expect(stats.available).toBe(3);
    expect(stats.inUse).toBe(0);
    expect(stats.error).toBe(0);
    expect(stats.waiting).toBe(0);
  });

  it('should acquire by type', async () => {
    const cpuResource = await pool.acquire('cpu');
    const gpuResource = await pool.acquire('gpu');

    expect(cpuResource.type).toBe('cpu');
    expect(gpuResource.type).toBe('gpu');
  });
});