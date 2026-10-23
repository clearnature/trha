# trha 架构设计

基于 Cordis 微内核思想的 Haskell 实现，参考 DeepSeek-Reasonix Studio v2.11.0 架构，实现前后端解耦、CLI/Desktop 共享核心。

## 1. 设计原则

| 原则 | 实现方式 |
|------|---------|
| **微内核** | 核心只管理插件生命周期，功能全部插件化 |
| **前后端解耦** | 核心库 `trha-core` 不依赖任何 UI 框架 |
| **CLI/Desktop 共享** | 通过 `trha-core` 统一 API，不同前端独立实现 |
| **可逆副作用** | Free Monad + bracket 模式确保资源清理 |
| **类型安全** | ExistentialQuantification + Typeable 实现运行时安全 |

## 2. 分层架构

```
┌─────────────────────────────────────────────────────┐
│                  Applications                        │
│   ┌──────────────┐  ┌──────────────┐  ┌──────────┐  │
│   │ CLI / TUI    │  │ Desktop      │  │ Web      │  │
│   │ (Terminal)   │  │ (Electron+   │  │ (React+  │  │
│   │              │  │  React)      │  │  Vite)   │  │
│   └──────┬───────┘  └──────┬───────┘  └─────┬─────┘  │
│          │                 │                │        │
│          └─────────────────┼────────────────┘        │
│                            │                         │
├────────────────────────────┼─────────────────────────┤
│                  Shared Core Layer                    │
│   ┌────────────────────────┴─────────────────────┐   │
│   │              trha-core                   │   │
│   │  ┌─────────┐ ┌─────────┐ ┌─────────┐        │   │
│   │  │ Plugin  │ │ Session │ │  Agent  │        │   │
│   │  │ System  │ │  Log    │ │  Loop   │        │   │
│   │  └─────────┘ └─────────┘ └─────────┘        │   │
│   │  ┌─────────┐ ┌─────────┐ ┌─────────┐        │   │
│   │  │  Tools  │ │   LLM   │ │  Event  │        │   │
│   │  │Registry │ │ Adapter │ │  Bus    │        │   │
│   │  └─────────┘ └─────────┘ └─────────┘        │   │
│   └──────────────────────────────────────────────┘   │
├──────────────────────────────────────────────────────┤
│                  Infrastructure Layer                 │
│   ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐  │
│   │Storage  │ │Network  │ │Sandbox  │ │ Telemetry│  │
│   │(JSON/SQL)│ │ (HTTP)  │ │(Process)│ │(Metrics)│  │
│   └─────────┘ └─────────┘ └─────────┘ └─────────┘  │
└──────────────────────────────────────────────────────┘
```

## 3. 核心模块详解

### 3.1 Plugin System (`Core.Plugin`)

```haskell
-- Free Monad DSL
data PluginF next
  = RegisterService String Dynamic next
  | SubscribeEvent String (Dynamic -> IO ()) next
  | ProvideEffect (IO (IO ())) next
  | forall a. WithContext (IO a) (a -> next)

type Plugin = Free PluginF
```

- **组合性**：`Plugin` 是 `Monoid`，支持 `<>` 组合
- **可逆性**：每个 `Effect` 返回清理动作
- **类型安全**：`Typeable` + `Dynamic` 实现运行时类型检查

### 3.2 Session Log (`Core.Session`)

参考 DeepSeek-Reasonix 的 `internal/store/session.go` 设计：

```haskell
data SessionEvent
  = UserMessage Text
  | AssistantMessage Text
  | ToolCall String Dynamic
  | ToolResult String Dynamic
  | SystemEvent String

data Session = Session
  { sessionId   :: SessionId
  , eventLog    :: IORef [SessionEvent]
  , projections :: IORef (Map String Dynamic)
  , agentState  :: IORef AgentState
  }
```

- **追加日志**：所有事件只追加，不可修改
- **可投影**：支持从日志重建任意状态视图
- **持久化**：内核会话快照（`sessionId` + `agentState`）落盘为
  `<stateDir>/kernel/<sessionId>.json`（`Infrastructure.Storage.SessionStore`，
  tmp+rename 原子写）。事件与投影含 `Dynamic`，是派生状态，**不进快照**——重启后
  由下一步重算。`<stateDir>` 取 `trha serve --state-dir`，缺省回落到
  `TRHA_STATE_DIR`（与编排层共用同一变量，但内核文件放在 `kernel/` 子目录，避免与
  编排层同名会话文件互相覆盖）

### 3.3 Agent Loop (`Core.Agent`)

```haskell
data Agent = Agent
  { agentId     :: AgentId
  , agentState  :: TVar AgentState
  , agentInbox  :: TQueue Message
  , agentConfig :: AgentConfig
  }

data AgentState
  = Idle
  | Processing StepId
  | WaitingForTool ToolCallId
  | Completed Result
  | Error ErrorType
```

- **状态机**：显式状态转换，易于推理和调试
- **STM 事务**：`TVar` + `TQueue` 保证并发安全
- **可中断**：支持外部中断和超时

### 3.4 Tool Registry (`Core.Tools`)

```haskell
data Tool = Tool
  { toolName        :: ToolName
  , toolDescription :: Text
  , toolSchema      :: JSONSchema
  , toolExecutor    :: Dynamic -> IO Dynamic
  }

data ToolRegistry = ToolRegistry
  { tools       :: IORef (Map ToolName Tool)
  , toolScopes  :: IORef (Map AgentId [ToolName])
  }
```

- **作用域**：每个 Agent 可见不同的工具子集
- **类型安全**：输入输出 JSON Schema 验证
- **可扩展**：支持动态注册/注销

### 3.5 Event Bus (`Core.Event`)

```haskell
data EventBus = EventBus
  { subscribers :: IORef (Map String [EventHandler])
  }

type EventHandler = Dynamic -> IO ()
```

- **发布/订阅**：解耦事件生产者和消费者
- **类型安全**：`Dynamic` 实现运行时类型检查
- **动态订阅**：支持运行时订阅/取消订阅

### 3.6 LLM Adapter (`LLM.Adapter`)

```haskell
data LLMAdapter = LLMAdapter
  { llmChat    :: [Message] -> IO [StreamChunk]
  , llmEmbed   :: Text -> IO [Float]
  , llmModels  :: IO [ModelInfo]
  }

data StreamChunk
  = ChunkDelta Text
  | ChunkToolCall Text [Text]
  | ChunkDone Usage
```

- **流式响应**：支持增量返回
- **多模型**：统一接口适配不同模型
- **可替换**：通过插件系统切换后端

## 4. 前端接口设计

### 4.1 Core API (所有前端共享)

```haskell
-- trha-core 导出的接口
data HarnessAPI = HarnessAPI
  { apiSendMessage    :: SessionId -> Text -> IO ()
  , apiCreateSession  :: IO SessionId
  , apiListSessions   :: IO [SessionId]
  , apiGetHistory     :: SessionId -> IO [SessionEvent]
  , apiSubscribeEvents :: (SessionEvent -> IO ()) -> IO ()
  , apiInterrupt      :: SessionId -> IO ()
  }
```

### 4.2 CLI Frontend

```
trha
├── Main.hs           # 入口
├── Commands/
│   ├── Chat.hs       # 交互式对话
│   ├── Run.hs        # 单次执行
│   └── Config.hs     # 配置管理
└── UI/
    ├── Terminal.hs   # ANSI 终端渲染
    └── Progress.hs   # 进度条/动画
```

### 4.3 Desktop Frontend (GTK/Qt) —— ⚠️ **非现状**

```
trha-desktop
├── Main.hs           # 入口
├── UI/
│   ├── MainWindow.hs # 主窗口
│   ├── ChatView.hs   # 对话视图
│   ├── Sidebar.hs    # 会话列表
│   └── Settings.hs   # 设置面板
└── State/
    └── AppState.hs   # 应用状态
```

### 4.4 Web Frontend (Warp + WebSocket) —— ⚠️ **非现状**

```
trha-web
├── Main.hs           # Warp 服务器
├── API/
│   ├── REST.hs       # RESTful API
│   └── WebSocket.hs  # WebSocket 实时通信
└── Static/
    └── index.html    # 前端资源
```

## 5. 数据流

```
用户输入
    │
    ▼
┌─────────────┐
│  Frontend   │ (CLI/Desktop/Web)
└──────┬──────┘
       │ HarnessAPI
       ▼
┌─────────────┐
│  Core.Agent │ Agent Loop
└──────┬──────┘
       │
       ▼
┌─────────────┐     ┌─────────────┐
│ Core.Session│────▶│  Storage    │ (JSON/SQLite)
└──────┬──────┘     └─────────────┘
       │
       ▼
┌─────────────┐
│  LLM.Adapter│ (DeepSeek API)
└──────┬──────┘
       │
       ▼
┌─────────────┐
│ Core.Tools  │ (文件系统/Shell/Web)
└─────────────┘
```

## 6. 包结构规划（⚠️ **规划，不是现状**）

> **⚠️ 本节是早期构想，从未采用。** 现状是**层根结构**：`src/` 下按层分目录（`Core/`、`LLM/`、`API/`、`Infrastructure/`、`Presentation/`），由**同一个 `trha.cabal` 内的 4 个 library**（`trha-core` / `trha-infra` / `trha-llm` / `trha-api`）**共享 `src` 作为层根** —— 而不是下面这种"每包独立目录"。
>
> **结构权威**是 `QWEN.md` §Architecture Layers / §Module naming；对账见 `docs/plans/code-docs-reconciliation.md` §6。
>
> **照下面这张图去重构目录会破坏既有约定**：2026-09-13 曾据此尝试按包重排 `src/`（68 个 rename），已全部回退。

```
trha/                      ← 以下为**未采用的规划**
├── trha-core/        # 核心库 (纯函数 + IO)
│   ├── Core/
│   │   ├── Plugin.hs
│   │   ├── Session.hs
│   │   ├── Agent.hs
│   │   ├── Tools.hs
│   │   └── Event.hs
│   └── LLM/
│       └── Adapter.hs
│
├── trha/                   # CLI 前端
│   └── Main.hs
│
├── trha-desktop/     # Desktop 前端
│   └── Main.hs
│
├── trha-web/         # Web 前端
│   └── Main.hs
│
└── trha-storage/     # 存储后端
    └── Storage/
        ├── JSON.hs
        └── SQLite.hs
```

## 7. 技术选型

| 组件 | 选择 | 理由 |
|------|------|------|
| **构建系统** | Cabal | 成熟稳定，支持多包工作区 |
| **并发** | STM | 类型安全的事务内存 |
| **HTTP 客户端** | http-client | 成熟稳定 |
| **JSON** | aeson | 性能优秀，TH 支持 |
| **终端 UI** | brick | 成熟的 TUI 框架 |
| **Desktop UI** | gi-gtk | GTK3 Haskell 绑定 |
| **Web 框架** | warp + scotty | 轻量高效 |
| **数据库** | sqlite-simple | 轻量级 SQL |
| **日志** | fast-logger | 高性能日志 |
| **测试** | hspec + QuickCheck | BDD + 属性测试 |

## 8. 下一步计划（⚠️ **本节是早期构想，未与现状同步**）

> **状态口径以 `project-overview.md` §3 为准。** 下面 5 条与 `README.md` §下一步 的 Phase 表
> **口径不同**（README 那张表带 2026-09-13 的实测注记），两者不一致时以 README / `project-overview.md` 为准。
> 2026-09-17 加注，避免再出现「同一件事在两份文档里一个 ✅ 一个未勾」。

1. **Phase 1**: 完成 `Core.Session` 和 `Core.Agent` ✅
2. **Phase 2**: 实现 `LLM.DeepSeek` 适配器 ✅
3. **Phase 3**: 开发 CLI 前端 —— ✅ 已建成（`packages/app/CLI`，`trha-cli-test` 182 例）
4. **Phase 4**: 实现存储后端 (JSON/SQLite) —— ✅ 已建成（`trha-infra`；会话持久化两层：编排层对话在 `stateStore.ts`，内核 FSM 快照在 `Infrastructure.Storage.SessionStore`）
5. **Phase 5**: 开发 Desktop/Web 前端 —— Desktop 🟡（Electron + React，**不是本文 §4.3 写的 GTK/Qt**；linux deb 已验，win/mac 与实机启动未验）；Web ❌ 空壳

> 另注：本文 §4.3 的 `trha-desktop（GTK/Qt）` 与 §4.4 的 `trha-web（Warp）` **均非现状** ——
> Desktop 是 Electron + React，Web 是 React + Vite。真实前端在 `packages/app/{Desktop,Web}`，
> 不在 `src/Presentation/**`（该层从未参与编译，见 `presentation-layer.md` 头部标注）。