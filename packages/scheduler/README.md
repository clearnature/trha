# trha Scheduler

TypeScript 调度层，用于 trha 代理系统。

## 概述

trha 调度层提供了：
- 插件系统
- 并行调度
- 子代理管理
- Haskell 桥接
- 事件系统

## 架构

```
┌─────────────────────────────────────────────────────────────┐
│                    Scheduler Layer                          │
│   ┌────────────────────────────────────────────────────┐   │
│   │                    Core                            │   │
│   │  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐  │   │
│   │  │ Client  │ │  HTTP   │ │ Logger  │ │  Retry  │  │   │
│   │  └─────────┘ └─────────┘ └─────────┘ └─────────┘  │   │
│   │  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐  │   │
│   │  │ Plugin  │ │ Parallel│ │Subagent │ │ Bridge  │  │   │
│   │  │ Manager │ │Scheduler│ │ Manager │ │ Haskell │  │   │
│   │  └─────────┘ └─────────┘ └─────────┘ └─────────┘  │   │
│   │  ┌─────────┐ ┌─────────┐                          │   │
│   │  │  Event  │ │  Queue  │                          │   │
│   │  │ Emitter │ │         │                          │   │
│   │  └─────────┘ └─────────┘                          │   │
│   └────────────────────────────────────────────────────┘   │
├─────────────────────────────────────────────────────────────┤
│                    Subagent System (Phase 6)                │
│   ┌────────────────────────────────────────────────────┐   │
│   │  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐  │   │
│   │  │ Manager │ │Protocol │ │ Session │ │  Error  │  │   │
│   │  │         │ │ Handler │ │ Manager │ │ Handler │  │   │
│   │  └─────────┘ └─────────┘ └─────────┘ └─────────┘  │   │
│   │  ┌─────────┐ ┌─────────┐                          │   │
│   │  │Transport│ │ Resource│                          │   │
│   │  │         │ │  Pool   │                          │   │
│   │  └─────────┘ └─────────┘                          │   │
│   └────────────────────────────────────────────────────┘   │
├─────────────────────────────────────────────────────────────┤
│                    Communication Layer                      │
│   ┌─────────┐ ┌─────────┐ ┌─────────┐                    │
│   │  HTTP   │ │  SSE    │ │  IPC    │                    │
│   └─────────┘ └─────────┘ └─────────┘                    │
└─────────────────────────────────────────────────────────────┘
```

## 模块

### Core 模块

| 模块 | 文件 | 职责 |
|------|------|------|
| **Core.Types** | `Core/Types.ts` | 类型定义 |
| **Core.Client** | `Core/Client.ts` | SDK 客户端 |
| **Core.HTTP** | `Core/HTTP.ts` | HTTP 客户端 |
| **Core.Logger** | `Core/Logger.ts` | 日志工具 |
| **Core.Retry** | `Core/Retry.ts` | 重试逻辑 |

### Plugin 模块

| 模块 | 文件 | 职责 |
|------|------|------|
| **Plugins.Plugin** | `Plugins/Plugin.ts` | 插件系统 |

### Parallel 模块

| 模块 | 文件 | 职责 |
|------|------|------|
| **Parallel.Scheduler** | `Parallel/Scheduler.ts` | 并行调度 |

### Subagent 模块 (Phase 6)

| 模块 | 文件 | 职责 |
|------|------|------|
| **Subagent.Manager** | `Subagent/Manager/Manager.ts` | 子代理管理 |
| **Subagent.Protocol** | `Subagent/Communication/Protocol.ts` | 通信协议 |
| **Subagent.Transport** | `Subagent/Communication/Transport.ts` | 传输层 |
| **Subagent.Session** | `Subagent/State/Session.ts` | 会话管理 |
| **Subagent.Error** | `Subagent/Error/Handler.ts` | 错误处理 |
| **Subagent.Resource** | `Subagent/Resource/Pool.ts` | 资源池 |

### Bridge 模块

| 模块 | 文件 | 职责 |
|------|------|------|
| **Bridge.Haskell** | `Bridge/Haskell.ts` | Haskell 桥接 |

### Utils 模块

| 模块 | 文件 | 职责 |
|------|------|------|
| **Utils.EventEmitter** | `Utils/EventEmitter.ts` | 事件发射器 |
| **Utils.Queue** | `Utils/Queue.ts` | 队列实现 |

## 核心特性

1. **插件系统**: 可扩展的插件架构
2. **并行调度**: 支持 parallel、pipeline、mapReduce
3. **子代理管理**: 独立进程的子代理
4. **Haskell 桥接**: 与 Haskell 核心引擎通信
5. **事件系统**: 发布/订阅事件模式
6. **重试逻辑**: 指数退避重试
7. **日志系统**: 结构化日志

## Phase 6: 多 Agent 协作系统

### 子代理管理

```typescript
import { SubAgentManager } from '@trha/scheduler';

const manager = new SubAgentManager({
  maxConcurrent: 5,
  defaultTimeout: 30000,
  defaultMaxRetries: 3,
  poolSize: 10,
});

// Spawn a subagent
const agent = await manager.spawn({
  model: 'deepseek-chat',
  tools: ['read_file', 'write_file'],
  timeout: 30000,
  maxRetries: 3,
  parentSessionId: 'parent-1',
});

// Submit a task
const task = await manager.submitTask(agent.id, { input: 'Analyze this file' });

// Get summary
const summary = await manager.getSummary();
console.log(`Completed: ${summary.completed}, Failed: ${summary.failed}`);
```

### 通信协议

```typescript
import { ProtocolHandler } from '@trha/scheduler';

const handler = new ProtocolHandler();

// Register handler
handler.registerHandler('execute', async (message) => {
  return { result: 'success' };
});

// Create and send message
const request = handler.createRequest('agent-1', 'agent-2', 'execute', { input: 'test' });
const response = await handler.handleMessage(request);
```

### 会话管理

```typescript
import { SessionManager } from '@trha/scheduler';

const manager = new SessionManager();

// Create session
const session = await manager.createSession('subagent-1', 'parent-1');

// Add messages
await manager.addMessage(session.id, 'user', 'Hello');
await manager.addMessage(session.id, 'assistant', 'Hi there!');

// Complete session
await manager.completeSession(session.id, 'completed');
```

### 错误处理

```typescript
import { ErrorHandler } from '@trha/scheduler';

const handler = new ErrorHandler({
  maxRetries: 3,
  retryDelay: 1000,
  retryBackoff: 2.0,
  logErrors: true,
});

// Handle error
const error = await handler.handleError(new Error('timeout'), {
  subagentId: 'agent-1',
  taskId: 'task-1',
});

console.log(`Error type: ${error.type}, Retryable: ${error.retryable}`);
```

### 资源池

```typescript
import { ResourcePool } from '@trha/scheduler';

const pool = new ResourcePool({
  maxSize: 10,
  minSize: 2,
  acquireTimeout: 5000,
  idleTimeout: 60000,
  maxRetries: 3,
});

// Initialize pool
await pool.initialize([
  { id: 'cpu-1', type: 'cpu', metadata: {} },
  { id: 'cpu-2', type: 'cpu', metadata: {} },
  { id: 'gpu-1', type: 'gpu', metadata: {} },
]);

// Acquire resource
const resource = await pool.acquire('cpu');

// Use resource
console.log(`Using resource: ${resource.id}`);

// Release resource
await pool.release(resource.id);
```

## 使用示例

### 创建客户端

```typescript
import { SchedulerClient } from '@trha/scheduler';

const client = new SchedulerClient({
  host: 'localhost',
  port: 3000,
});

// 创建会话
const sessionId = await client.createSession();

// 发送消息
await client.sendMessage(sessionId, 'Hello!');
```

### 并行调度

```typescript
import { ParallelScheduler } from '@trha/scheduler';

const scheduler = new ParallelScheduler({ maxConcurrency: 4 });

const tasks = [
  { id: '1', execute: async () => fetch('https://api1.example.com') },
  { id: '2', execute: async () => fetch('https://api2.example.com') },
  { id: '3', execute: async () => fetch('https://api3.example.com') },
];

const results = await scheduler.parallel(tasks);
```

## 构建

```bash
cd scheduler
npm install
npm run build
```

## 测试

```bash
cd scheduler
npm test
```

## 技术栈

| 组件 | 技术 | 职责 |
|------|------|------|
| **语言** | TypeScript | 类型安全 |
| **HTTP** | axios | HTTP 客户端 |
| **日志** | winston | 结构化日志 |
| **验证** | zod | 数据验证 |
| **测试** | vitest | 测试框架 |

## 下一步

1. **Phase 5**: 调度层 (TypeScript) ✅
2. **Phase 6**: 并行子代理 (Pi) ✅
3. **Phase 7**: 前端集成