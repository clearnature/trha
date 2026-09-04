# 代码迁移计划

## 概述

从四个源代码项目中提取核心代码，构建融合架构。

## 1. DeepSeek-Harness 代码提取

### 1.1 Cordis 插件系统

**源文件**: `packages/core/agent/src/index.ts`

```typescript
// 提取插件注册逻辑
export function registerPlugin(ctx: Context, plugin: Plugin) {
  ctx.effect(() => {
    plugin.activate(ctx)
    return () => plugin.deactivate?.()
  })
}
```

**目标文件**: `src/orchestration/plugins/cordis.ts`

### 1.2 会话管理

**源文件**: `packages/core/session/src/index.ts`

```typescript
// 提取会话逻辑
export class Session {
  constructor(public id: string) {}
  
  appendEvent(event: SessionEvent): void {
    // 追加事件到日志
  }
  
  getEvents(): SessionEvent[] {
    return this.events
  }
}
```

**目标文件**: `src/orchestration/session/manager.ts`

### 1.3 工具注册

**源文件**: `packages/core/tools/src/index.ts`

```typescript
// 提取工具注册逻辑
export class ToolRegistry {
  private tools = new Map<string, Tool>()
  
  register(tool: Tool): void {
    this.tools.set(tool.name, tool)
  }
  
  get(name: string): Tool | undefined {
    return this.tools.get(name)
  }
}
```

**目标文件**: `src/orchestration/tools/registry.ts`

## 2. Pi 代码提取

### 2.1 并行调度

**源文件**: `packages/agent/src/parallel.ts`

```typescript
// 提取并行逻辑
export async function parallel<T>(
  tasks: (() => Promise<T>)[]
): Promise<T[]> {
  return Promise.all(tasks.map(t => t()))
}

export async function pipeline<T>(
  stages: ((input: T) => Promise<T>)[],
  initial: T
): Promise<T> {
  let current = initial
  for (const stage of stages) {
    current = await stage(current)
  }
  return current
}
```

**目标文件**: `src/orchestration/parallel/scheduler.ts`

### 2.2 子代理管理

**源文件**: `packages/agent/src/subagent.ts`

```typescript
// 提取子代理逻辑
export class SubAgentManager {
  private agents = new Map<string, SubAgent>()
  
  async spawn(config: SubAgentConfig): Promise<SubAgent> {
    const agent = new SubAgent(config)
    this.agents.set(agent.id, agent)
    return agent
  }
  
  async terminate(id: string): Promise<void> {
    const agent = this.agents.get(id)
    if (agent) {
      await agent.terminate()
      this.agents.delete(id)
    }
  }
}
```

**目标文件**: `src/orchestration/subagent/manager.ts`

### 2.3 LLM 适配器

**源文件**: `packages/ai/src/providers/deepseek.ts`

```typescript
// 提取 DeepSeek 适配器
export class DeepSeekAdapter implements LLMAdapter {
  constructor(private apiKey: string) {}
  
  async chat(messages: Message[]): Promise<StreamChunk[]> {
    // 调用 DeepSeek API
  }
  
  async embed(text: string): Promise<number[]> {
    // 获取嵌入向量
  }
}
```

**目标文件**: `src/orchestration/llm/deepseek.ts`

## 3. DeepSeek-Reasonix 代码提取

### 3.1 缓存引擎

**源文件**: `internal/store/session.go`

```go
// 提取缓存逻辑
type CacheEngine struct {
  store map[string]interface{}
  mu    sync.RWMutex
}

func (c *CacheEngine) Lookup(key string) (interface{}, bool) {
  c.mu.RLock()
  defer c.mu.RUnlock()
  val, ok := c.store[key]
  return val, ok
}
```

**目标文件**: `src/core-engine/Cache.hs` (Haskell 重写)

### 3.2 会话存储

**源文件**: `internal/store/session.go`

```go
// 提取会话存储逻辑
type Session struct {
  ID        string
  EventLog  []Event
  Projections map[string]interface{}
}

func (s *Session) AppendEvent(event Event) {
  s.EventLog = append(s.EventLog, event)
}
```

**目标文件**: `src/core-engine/Session.hs` (Haskell 重写)

## 4. trha 代码整合

### 4.1 核心模块

**源文件**: `src/Core/*.hs`

```haskell
-- 已实现的模块
module Core.Plugin (Plugin, PluginF(..), runPlugin)
module Core.Session (Session, SessionEvent(..), createSession, appendEvent)
module Core.Agent (Agent, AgentState(..), createAgent, updateState)
module Core.Tools (Tool, ToolRegistry, createToolRegistry, registerTool)
module Core.Event (EventBus, createEventBus, subscribe, publish)
```

**目标**: 保持现有实现，扩展功能

### 4.2 LLM 适配器

**源文件**: `src/LLM/Adapter.hs`

```haskell
-- 已实现的适配器
data LLMAdapter = LLMAdapter
  { llmChat :: [Message] -> IO [StreamChunk]
  , llmEmbed :: Text -> IO [Float]
  , llmModels :: IO [ModelInfo]
  }
```

**目标**: 集成 DeepSeek API

## 5. 融合架构实现

### 5.1 核心引擎 (Haskell)

**目标文件**: `src/core-engine/`

```haskell
-- 缓存引擎
module CoreEngine.Cache (CacheEngine, createCache, lookup, insert)

-- 类型检查器
module CoreEngine.TypeChecker (TypeChecker, checkType, verifyType)

-- 形式化验证
module CoreEngine.Verifier (Verifier, verifyInvariant, proveProperty)

-- 推理引擎
module CoreEngine.Reasoner (Reasoner, reason, solve)
```

### 5.2 调度层 (TypeScript)

**目标文件**: `src/orchestration/`

```typescript
// Cordis 插件系统
export { CordisContext, Plugin } from './plugins/cordis'

// 会话管理
export { SessionManager } from './session/manager'

// 工具注册
export { ToolRegistry } from './tools/registry'

// 并行调度
export { parallel, pipeline, mapReduce } from './parallel/scheduler'

// 子代理管理
export { SubAgentManager } from './subagent/manager'

// LLM 适配器
export { DeepSeekAdapter } from './llm/deepseek'
```

### 5.3 前端层

**目标文件**: `src/presentation/`

```typescript
// Electron 桌面应用
export { DesktopApp } from './electron/app'

// Web UI (React)
export { WebApp } from './web/app'

// TUI (Pi 风格)
export { TUIApp } from './tui/app'
```

## 6. 迁移步骤

### Phase 1: 核心引擎 (1 周)
- [ ] 从 Reasonix 提取缓存逻辑
- [ ] 从 trha 整合核心模块
- [ ] 实现 Haskell servant API

### Phase 2: 调度层 (1 周)
- [ ] 从 DeepSeek-Harness 提取 Cordis 系统
- [ ] 从 Pi 提取并行调度逻辑
- [ ] 实现 TypeScript 调度层

### Phase 3: 前端集成 (1 周)
- [ ] 从各项目提取前端代码
- [ ] 实现统一前端接口
- [ ] 前后端联调

### Phase 4: 测试验证 (1 周)
- [ ] 单元测试
- [ ] 集成测试
- [ ] 性能测试

## 7. 代码质量保证

### 7.1 类型安全
- Haskell: Liquid Haskell 形式化验证
- TypeScript: strict 模式 + ESLint

### 7.2 测试覆盖
- Haskell: hspec + QuickCheck
- TypeScript: vitest + jest

### 7.3 代码审查
- 每个 PR 必须通过代码审查
- 自动化 CI/CD 流水线