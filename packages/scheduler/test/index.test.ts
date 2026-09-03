// Tests for gh-harness scheduler

import { describe, it, expect } from 'vitest';
import { SchedulerClient } from '../src/Core/Client.js';
import { ParallelScheduler } from '../src/Parallel/Scheduler.js';
import { SubAgentManager } from '../src/Subagent/Manager.js';
import { PluginManager } from '../src/Plugins/Plugin.js';
import { EventEmitter } from '../src/Utils/EventEmitter.js';
import { Queue } from '../src/Utils/Queue.js';
import { withRetry, defaultRetryConfig } from '../src/Core/Retry.js';
import { createLogger } from '../src/Core/Logger.js';

describe('Core', () => {
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
  });

  describe('Retry', () => {
    it('should have default config', () => {
      expect(defaultRetryConfig.maxAttempts).toBe(3);
      expect(defaultRetryConfig.delay).toBe(1000);
      expect(defaultRetryConfig.backoff).toBe(2.0);
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

describe('Plugins', () => {
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

describe('Parallel', () => {
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

describe('Subagent', () => {
  describe('SubAgentManager', () => {
    it('should spawn and terminate agents', async () => {
      const manager = new SubAgentManager();

      const agent = await manager.spawn({
        model: 'deepseek-chat',
        tools: ['read_file'],
        timeout: 30000,
      });

      expect(agent.id).toBeDefined();
      expect(agent.state).toBe('idle');

      await manager.terminate(agent.id);
      const agents = await manager.listAgents();
      expect(agents).toHaveLength(0);
    });

    it('should update agent state', async () => {
      const manager = new SubAgentManager();

      const agent = await manager.spawn({
        model: 'deepseek-chat',
        tools: ['read_file'],
        timeout: 30000,
      });

      await manager.updateState(agent.id, 'completed', { result: 'success' });

      const updated = await manager.getAgent(agent.id);
      expect(updated?.state).toBe('completed');
      expect(updated?.result).toEqual({ result: 'success' });
    });
  });
});

describe('Utils', () => {
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