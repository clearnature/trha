// Core module smoke tests

import { describe, it, expect, beforeEach } from 'vitest';
import {
  SchedulerClient,
  ParallelScheduler,
  SubAgentManager,
  PluginManager,
  EventEmitter,
  Queue,
  withRetry,
  createLogger,
} from '../../packages/scheduler/src/index.js';

describe('Core Module Smoke Tests', () => {
  describe('SchedulerClient', () => {
    it('should create client with default config', () => {
      const client = new SchedulerClient();
      expect(client).toBeDefined();
    });

    it('should create client with custom config', () => {
      const client = new SchedulerClient({
        host: 'example.com',
        port: 8080,
        timeout: 60000,
      });
      expect(client).toBeDefined();
    });
  });

  describe('Logger', () => {
    it('should create logger', () => {
      const logger = createLogger('info', 'test');
      expect(logger).toBeDefined();
    });

    it('should log messages', () => {
      const logger = createLogger('info', 'test');
      // Just verify it doesn't throw
      logger.info('Test message');
      logger.warn('Test warning');
      logger.error('Test error');
    });
  });

  describe('Retry', () => {
    it('should have default config', () => {
      expect(withRetry).toBeDefined();
    });

    it('should retry on failure', async () => {
      let attempts = 0;
      const fn = async () => {
        attempts++;
        if (attempts < 3) {
          throw new Error('Fail');
        }
        return 'success';
      };

      const result = await withRetry(fn, { maxAttempts: 3, delay: 10, backoff: 1.0 });
      expect(result).toBe('success');
      expect(attempts).toBe(3);
    });
  });
});

describe('Plugin System', () => {
  describe('PluginManager', () => {
    it('should register and unregister plugins', async () => {
      const manager = new PluginManager();
      const plugin = {
        name: 'test',
        version: '1.0.0',
        description: 'Test plugin',
      };

      await manager.register(plugin);
      expect(manager.listPlugins()).toHaveLength(1);

      await manager.unregister('test');
      expect(manager.listPlugins()).toHaveLength(0);
    });

    it('should emit events', async () => {
      const manager = new PluginManager();
      let called = false;

      const plugin = {
        name: 'test',
        version: '1.0.0',
        description: 'Test plugin',
        onSessionCreate: async () => {
          called = true;
        },
      };

      await manager.register(plugin);
      await manager.emitSessionCreate('session-1');
      expect(called).toBe(true);
    });
  });
});

describe('Parallel Scheduler', () => {
  describe('ParallelScheduler', () => {
    it('should execute tasks in parallel', async () => {
      const scheduler = new ParallelScheduler({ maxConcurrency: 2 });

      const tasks = [
        { id: '1', execute: async () => 1 },
        { id: '2', execute: async () => 2 },
        { id: '3', execute: async () => 3 },
      ];

      const results = await scheduler.parallel(tasks);
      expect(results).toHaveLength(3);
    });

    it('should handle pipeline', async () => {
      const scheduler = new ParallelScheduler({ maxConcurrency: 1 });

      const stages = [
        async (input: number) => input + 1,
        async (input: number) => input * 2,
      ];

      const result = await scheduler.pipeline(stages, 1);
      expect(result).toBe(4); // (1 + 1) * 2
    });

    it('should handle mapReduce', async () => {
      const scheduler = new ParallelScheduler({ maxConcurrency: 2 });

      const items = [1, 2, 3, 4, 5];
      const mapper = async (item: number) => item * 2;
      const reducer = (results: number[]) => results.reduce((a, b) => a + b, 0);

      const result = await scheduler.mapReduce(items, mapper, reducer);
      expect(result).toBe(30); // (2 + 4 + 6 + 8 + 10)
    });
  });
});

describe('SubAgent Manager', () => {
  describe('SubAgentManager', () => {
    it('should spawn and terminate agents', async () => {
      const manager = new SubAgentManager({
        maxConcurrent: 5,
        defaultTimeout: 30000,
        defaultMaxRetries: 3,
        poolSize: 10,
      });

      const agent = await manager.spawn({
        model: 'deepseek-chat',
        tools: ['read_file'],
        timeout: 30000,
        maxRetries: 3,
        parentSessionId: 'parent-1',
      });

      expect(agent.id).toBeDefined();
      expect(agent.status).toBe('idle');

      await manager.terminate(agent.id);
      const agents = await manager.listAgents();
      expect(agents).toHaveLength(0);
    });

    it('should update agent state', async () => {
      const manager = new SubAgentManager({
        maxConcurrent: 5,
        defaultTimeout: 30000,
        defaultMaxRetries: 3,
        poolSize: 10,
      });

      const agent = await manager.spawn({
        model: 'deepseek-chat',
        tools: ['read_file'],
        timeout: 30000,
        maxRetries: 3,
        parentSessionId: 'parent-1',
      });

      await manager.updateState(agent.id, 'completed', { result: 'success' });

      const updated = await manager.getAgent(agent.id);
      expect(updated?.status).toBe('completed');
      expect(updated?.result).toEqual({ result: 'success' });
    });
  });
});

describe('Event Emitter', () => {
  describe('EventEmitter', () => {
    it('should emit and listen events', async () => {
      const emitter = new EventEmitter();
      let received: string | undefined;

      emitter.on<string>('test', (data) => {
        received = data;
      });

      await emitter.emit('test', 'hello');
      expect(received).toBe('hello');
    });

    it('should handle once listeners', async () => {
      const emitter = new EventEmitter();
      let count = 0;

      emitter.once('test', () => {
        count++;
      });

      await emitter.emit('test', undefined);
      await emitter.emit('test', undefined);
      expect(count).toBe(1);
    });
  });
});

describe('Queue', () => {
  describe('Queue', () => {
    it('should enqueue and dequeue items', () => {
      const queue = new Queue<number>();

      queue.enqueue(1);
      queue.enqueue(2);
      queue.enqueue(3);

      expect(queue.size).toBe(3);
      expect(queue.dequeue()).toBe(1);
      expect(queue.dequeue()).toBe(2);
      expect(queue.dequeue()).toBe(3);
      expect(queue.isEmpty).toBe(true);
    });

    it('should peek at front item', () => {
      const queue = new Queue<string>();

      queue.enqueue('a');
      queue.enqueue('b');

      expect(queue.peek()).toBe('a');
      expect(queue.size).toBe(2);
    });
  });
});