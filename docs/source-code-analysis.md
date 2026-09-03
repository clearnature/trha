# 源代码分析报告

## 概述

本报告分析了四个项目的源代码结构，为构建融合架构提供参考。

## 1. DeepSeek-Harness (TypeScript/Cordis)

### 项目结构
```
packages/
├── core/           # 核心 API
│   ├── session/    # 会话管理
│   ├── agent/      # Agent 循环
│   ├── tools/      # 工具注册
│   └── system-prompt/ # 系统提示
├── api/            # 远程 API 网关
├── llm/            # LLM 适配器
├── web/            # Web 能力
├── fs/             # 文件系统
├── shell/          # Shell 能力
├── subagent/       # 子代理
├── workflow/       # 工作流
└── bundle/         # 配置包
```

### 核心特性
- **Cordis 框架**：一切皆插件，可逆副作用
- **声明式配置**：cordis.yml + patch.yml
- **类型安全**：TypeScript strict 模式
- **热重载**：开发时 HMR 支持

### 关键代码
```typescript
// 插件注册
ctx.effect(() => {
  ctx.provide('llm', new LLMService())
  return () => ctx.dispose('llm')
})

// 事件系统
ctx.on('session/event', (event) => {
  // 处理会话事件
})
```

## 2. Pi (TypeScript/Node.js)

### 项目结构
```
packages/
├── agent/          # Agent 核心运行时
├── ai/             # 统一 LLM API
├── coding-agent/   # 交互式编码 CLI
├── tui/            # 终端 UI 库
├── telemetry/      # 遥测
└── protocol/       # 通信协议
```

### 核心特性
- **并行子代理**：独立进程隔离
- **多模型支持**：OpenAI/Anthropic/Google 统一 API
- **差异渲染**：高性能 TUI
- **工具调用**：类型安全的工具系统

### 关键代码
```typescript
// 并行执行
const results = await parallel([
  () => searchWeb('query'),
  () => readFile('file'),
  () => callAPI('endpoint')
])

// 子代理管理
const subagent = await spawnSubagent({
  model: 'deepseek-chat',
  tools: ['read_file', 'write_file']
})
```

## 3. DeepSeek-Reasonix (Go)

### 项目结构
```
internal/
├── agent/          # Agent 核心逻辑
├── store/          # 会话存储
├── tool/           # 工具系统
├── sandbox/        # 沙箱隔离
├── remote/         # 远程主机
├── plugin/         # 插件系统
└── serve/          # HTTP 服务
```

### 核心特性
- **缓存优先循环**：99.82% 缓存命中率
- **高性能存储**：JSONL 追加日志
- **沙箱隔离**：进程级隔离
- **热重载**：插件动态加载

### 关键代码
```go
// 缓存查找
func (c *Cache) Lookup(key string) (interface{}, bool) {
    c.mu.RLock()
    defer c.mu.RUnlock()
    val, ok := c.store[key]
    return val, ok
}

// 会话存储
type Session struct {
    ID        string
    EventLog  []Event
    Projections map[string]interface{}
}
```

## 4. gh-harness (Haskell/GHC)

### 项目结构
```
src/
├── Core/
│   ├── Plugin.hs   # Free Monad 插件系统
│   ├── Session.hs  # 会话事件日志
│   ├── Agent.hs    # 状态机 + STM
│   ├── Tools.hs    # 工具注册表
│   └── Event.hs    # 发布/订阅事件总线
└── LLM/
    └── Adapter.hs  # DeepSeek 适配器
```

### 核心特性
- **类型论推理**：编译时保证正确性
- **Free Monad**：可组合副作用
- **STM 事务**：类型安全并发
- **形式化验证**：Liquid Haskell 支持

### 关键代码
```haskell
-- Free Monad 插件
data PluginF next
  = RegisterService String Dynamic next
  | SubscribeEvent String (Dynamic -> IO ()) next
  | ProvideEffect (IO (IO ())) next

-- 状态机
data AgentState = Idle | Processing | Waiting | Completed | Error

-- STM 并发
updateState :: Agent -> AgentState -> IO ()
updateState agent newState = 
  atomically $ writeTVar (agentState agent) newState
```

## 5. 融合架构映射

### 功能映射表

| 功能 | DeepSeek-Harness | Pi | Reasonix | gh-harness |
|------|-----------------|-----|----------|------------|
| **插件系统** | Cordis | - | Go Plugin | Free Monad |
| **并行调度** | Subagent | parallel() | - | STM |
| **缓存** | - | - | Cache-First | 纯函数缓存 |
| **类型安全** | TypeScript | TypeScript | Go | Haskell |
| **会话管理** | Session | Session | Session | Session |
| **工具系统** | Tools | Tools | Tool | Tools |
| **事件系统** | Events | Events | Events | Event Bus |

### 技术栈映射

| 层 | DeepSeek-Harness | Pi | Reasonix | gh-harness |
|---|-----------------|-----|----------|------------|
| **前端** | Web UI | TUI/CLI | Desktop | Electron |
| **调度** | Cordis | Agent Core | Control | Cordis |
| **核心** | TypeScript | TypeScript | Go | Haskell |
| **存储** | JSON/SQLite | JSON | JSONL | IORef |
| **通信** | HTTP/SSE | HTTP | HTTP | servant |

## 6. 融合方案

### 6.1 核心引擎 (Haskell)

从 gh-harness 继承：
- 类型论推理
- Free Monad 插件系统
- STM 并发控制
- 形式化验证

从 Reasonix 继承：
- 缓存优先循环
- 高性能存储设计

### 6.2 调度层 (TypeScript)

从 DeepSeek-Harness 继承：
- Cordis 插件系统
- 声明式配置
- 热重载支持

从 Pi 继承：
- 并行子代理
- 多模型支持
- 差异渲染

### 6.3 前端层

从各项目继承最佳实践：
- **Desktop**：Electron (Reasonix)
- **Web**：React (DeepSeek-Harness)
- **TUI**：Pi TUI (Pi)

## 7. 关键代码迁移

### 7.1 从 Reasonix 迁移缓存

```haskell
-- Haskell 实现 Reasonix 缓存
data CacheEngine = CacheEngine
  { cacheStore :: IORef (Map CacheKey Dynamic)
  , cacheHits  :: IORef Int
  , cacheMisses :: IORef Int
  }

cacheLookup :: CacheEngine -> CacheKey -> IO (Maybe Dynamic)
cacheLookup engine key = do
  store <- readIORef (cacheStore engine)
  case Map.lookup key store of
    Just val -> do
      modifyIORef (cacheHits engine) (+1)
      return (Just val)
    Nothing -> do
      modifyIORef (cacheMisses engine) (+1)
      return Nothing
```

### 7.2 从 Pi 迁移并行

```typescript
// TypeScript 实现 Pi 并行
async function parallel<T>(tasks: (() => Promise<T>)[]): Promise<T[]> {
  return Promise.all(tasks.map(t => t()))
}

async function pipeline<T>(
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

### 7.3 从 DeepSeek-Harness 迁移插件

```typescript
// Cordis 插件系统
interface Plugin {
  name: string
  activate(ctx: Context): void
  deactivate?(): void
}

// 注册插件
ctx.plugin({
  name: 'agent-loop',
  activate(ctx) {
    ctx.on('session/start', async (session) => {
      // Agent 循环逻辑
    })
  }
})
```

## 8. 下一步行动

1. **代码迁移**：从各项目提取核心代码
2. **接口设计**：定义跨语言 API
3. **原型开发**：构建最小可行产品
4. **测试验证**：确保各组件协同工作
5. **性能优化**：缓存命中率 > 99%