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
  | ToolCall String Value        -- JSON payload，可落盘可回读
  | ToolResult String Value
  | SystemEvent String
  | AgentStateChanged AgentState  -- 让日志可重放

data Session = Session
  { sessionId   :: SessionId
  , eventLog    :: IORef [SessionEvent]
  , projections :: IORef (Map String Dynamic)
  , agentState  :: IORef AgentState
  }
```

- **追加日志**：所有事件只追加，不可修改
- **可投影**：支持从日志重建任意状态视图
- **可重放**：每次 FSM 推进都追加 `AgentStateChanged`，状态即日志上的 fold
- **持久化**（`Infrastructure.Storage.SessionStore`，两个文件一套）：
  - checkpoint `<stateDir>/kernel/<id>.json`：`sessionId` + `agentState` +
    `eventCount`（该状态已涵盖多少条事件），tmp+rename 原子写；
  - 事件日志 `<stateDir>/kernel/<id>.events.jsonl`：一事件一行、就地追加，
    写一步的代价与历史长度无关；末尾被截断的半行在读取时跳过，不牵连整段历史。
  - **写序**：先日志后 checkpoint。崩在两次写之间时日志领先 checkpoint，
    重启由 `restoreSession` 重放 `drop eventCount` 的尾部补齐；反之（日志比
    checkpoint 短）以 checkpoint 为准。
  - 投影仍是 `Dynamic` 派生状态，两个文件都不含它——重启后由下一步重算。
  - `<stateDir>` 取 `trha serve --state-dir`，缺省回落到 `TRHA_STATE_DIR`
    （与编排层共用同一变量，但内核文件在 `kernel/` 子目录，避免与编排层同名
    会话文件互相覆盖）。
  - 观测：`GET /session/<id>/events` 返回内核侧视角的日志（重启后即来自磁盘）。

### 3.3 审批闸门（命令屏障）

内核不执行工具，也不执行被批准的动作 —— 它只决定「能不能过」。闸门是 FSM 里的
一个状态，不是宿主侧的一个布尔字段：

```haskell
data AgentState
  = Idle | Processing StepId | WaitingForTool ToolCallId
  | AwaitingApproval ApprovalRequest     -- 有待决命令
  | Completed Result | Error ErrorType

data AgentCommand
  = StartCommand StepId | ToolCallCommand ToolCallId String | ToolResultCommand String
  | CompleteCommand Result | ErrorCommand ErrorType
  | RequestApprovalCommand ApprovalRequest   -- 挂起
  | ApproveCommand | RejectCommand           -- 放行 / 否决
```

- **屏障是真的**：`AwaitingApproval` 下 `StartCommand`/`ToolCallCommand`/…全部落到
  「保持不变」分支，且 `/agent/step` 直接返回 409 `approval.pending`；
  `/v1/chat/completions` 的内核触点也不推进 FSM。待决期间没有命令能偷跑。
- **放行 ≠ 执行**：批准与否决都回到 `Idle`。批准只是「这条命令现在可以跑了」，
  执行归宿主（scheduler 拿到 `approved` 后自己跑工具）。否决不置 `Error` ——
  拒绝是一条决策，不是会话故障。
- **一次只能挂一条**：待决时再申请返回 409；重复决策第二次得 400 `approval.none`
  （`decideApproval` 用 `atomicModifyIORef'` 做「检查+决策」一步，双击不会双赢）。
- **落盘可跨重启**：`AwaitingApproval` 与其中的 `ApprovalRequest` 都是 JSON，
  checkpoint 里原样保存；重启后闸门仍在，决策照常生效。事件日志记
  `approval_requested` / `approval_decided`。
- **端点**（两个，都在 `/session/<id>/` 下）：

| 方法/路径 | 请求 | 响应 |
|---|---|---|
| POST `/session/<id>/approval` | `{message, action?}` | `{status:"awaiting_approval", pending:{id,action,message}, agentState}`；已挂起 → 409 `approval.pending` |
| POST `/session/<id>/decision` | `{approve: bool}` | `{status:"approved"\|"denied", requestId, agentState}`；无待决 → 400 `approval.none` |
- **分工**：编排层 `/api/agent/step {requireApproval}` 与 `/api/session/:id/decision`
  委托这两个端点（内核不可达时降级回本地 `pendingApproval`），外壳协议形状不变。

#### 多步计划（逐步批准）

计划在**宿主**手里产生、由**宿主**执行；内核只回答两件事：「这一步现在可以跑吗」
「跑到哪了」。于是步骤内容不需要内核懂，闸门与进度却只有一个事实源。

```haskell
data Plan = Plan { planId, planMode :: PlanMode, planSteps :: [PlanStep] }
data PlanStep = PlanStep { planStepId, planStepTitle, planStepAction :: Value
                         , planStepStatus :: StepStatus }
data StepStatus = Pending | Approved | Skipped | Rejected | Done | Failed
```

- **相位**：`Idle --提交计划--> Planning --批准某步--> ExecutingStep sid --回报--> Planning
  | (无剩余) Idle`。`Planning` 是屏障（`/agent/step` → 409 `plan.active`）；
  `ExecutingStep` 则是执行窗口 —— 宿主正是要在这个相位跑那一步，所以放行，
  否则它就是「被批准但无路可走」。两次提交计划得 409（先放弃再重提）。
- **批准 ≠ 执行**：`Approved` 只表示可以跑；宿主跑完必须回报（`Done`/`Failed`），
  内核不会替它猜——进度才不会是谎言。这样 `StepApproved` 也是「还在宿主手里」的
  标记，`planFinished` 因此要求「无 pending 且无 approved」。
- **拒绝与跳过都支持**：`action: "reject"` 把该步记为 `Rejected` 并停住计划
  （后续保留 `Pending` 作记录，会话回 `Idle`）；`action: "skip"` 记为 `Skipped`
  并继续下一条。
- **落盘**：计划存在会话里（`sessionPlan`），随 checkpoint 一起写（`v:3` 起有
  `plan` 字段）；每次变动都追加 `PlanChanged plan` 事件（整份计划快照，无需额外
  reducer），重启时 checkpoint + 日志尾部重放共同还原。
- **端点**：

| 方法/路径 | 请求 | 响应 |
|---|---|---|
| GET `/session/<id>/plan` | – | `{plan, agentState}` |
| POST `/session/<id>/plan` | `{mode?, steps:[{id?, title, action?}]}` | `{status:"planning", plan, pending}`；已在进行 → 409 `plan.active`；空计划 → 400 `plan.empty` |
| POST `/session/<id>/step-result` | `{stepId, ok, output?}` | `{status:"step_done"\|"step_failed", plan, pending, agentState}`；该步未放行 → 409 `plan.no_step` |

  `decision` 端点同时服务两种粒度：`{approve:bool}`（单命令闸门）与
  `{action:"approve"|"skip"|"reject"|"abandon"}`（计划步骤）。
- **编排层**：`/api/session/:id/{plan,step-result}` 与带 `action` 的 `decision`
  都是薄转发，scheduler 不保留计划副本，避免进度两份漂移。
- **外壳怎么驱动**：CLI `/plan a; b; c`（`;` 或换行分隔）提交多步计划；TUI 的计划卡片
  与 Desktop 的 `PlanStepsCard` 都只渲染内核状态（步骤+状态+待决标记），四个动作分别
  对应 `approve/skip/reject/abandon`。**批准只放行**，随后由外壳把该步当成一次普通
  agent step 跑掉，再用 `step-result` 回报 —— 三个外壳同一套形状，内核因此不需要
  猜执行结果。互斥由相位保证：`Planning` 时 `/agent/step` 409，`ExecutingStep`
  时放行（那正是执行窗口）。
- **未实现**：`mode:"auto"`（一次放行全部）会被拒绝为 `plan.mode_unsupported`；
  计划本身仍要宿主给出（内核不做 planner）。

### 3.4 Agent Loop (`Core.Agent`)

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

### 3.5 Tool Registry (`Core.Tools`)

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

### 3.6 Event Bus (`Core.Event`)

```haskell
data EventBus = EventBus
  { subscribers :: IORef (Map String [EventHandler])
  }

type EventHandler = Dynamic -> IO ()
```

- **发布/订阅**：解耦事件生产者和消费者
- **类型安全**：`Dynamic` 实现运行时类型检查
- **动态订阅**：支持运行时订阅/取消订阅

### 3.7 缓存计量与上下文治理

两件事决定真实账单，且必须分开看。

**前缀缓存（provider 侧）**。DeepSeek 按前缀缓存计费，命中量在
`usage.prompt_cache_hit_tokens` / `prompt_cache_miss_tokens`。`Usage` 带这两个字段
（`mkUsage` 给不报告的 provider 留零），所以每一步、每个 SSE `usage` 帧、
`/api/usage-stats` 都能看到真实命中，而不是按字符数估。实测（`test/DeepSeekCacheSpec.hs`，
真实 API）：稳定 25k token 前缀 + 短增量，稳态命中 **99.54%**（req2–4: 99.57/99.54/99.51）。
条件只有三条：**追加式历史**（每轮只加，不改）、**稳定 system/tools 顺序**、
**不把时间戳之类易变内容塞进前缀**。

**上下文治理（scheduler 侧，`Server/contextGovernor.ts`）**。阈值抄 Reasonix：
窗口 60% snip / 80% fold / 90% force，尾部 16% 逐字保留；区域小于 400 token 不做折叠
（省下的还不够付一次调用）。压力量用 provider 上一轮的真实 `prompt_tokens`，没有才估算。
折叠出的标记是固定文本（无时间戳/随机数），所以**压缩后前缀重新稳定**，只在压缩那一步
付一次 cache miss；`prefixResets` 把这个代价显式计出来。折叠保留 **system 块 + 首条
用户消息**（任务陈述），实测这是性价比最高的一个开关。

实测（`docs/evidence/deepseek-context-pareto.md`，window 压到 1000 以触发治理）：

| arm | prompt | hit% | billed | recall |
|---|---|---|---|---|
| 无治理 | 15078 | 83.19% | 3844 | yes |
| fold（折掉任务陈述） | 6348 | 56.46% | 3213 | **NO** |
| fold+keephead | 6588 | 54.40% | **3380** | yes |

结论：**看命中率会做出错误决策** —— 不治理的命中率最高但账单最贵（缓存不是免费）；
而 `fold+keephead` 比最便宜的 `fold` 只贵 5%，却保住 100% 召回，是前沿上的实用点。

配置：`TRHA_LLM_MODEL`（默认 `deepseek-flash`）、`TRHA_REASONING_EFFORT`
（low/high/max；默认交给 API，实测 high 会把输出预算的大半烧在 reasoning 上）、
`TRHA_CONTEXT_WINDOW`（覆盖窗口，测试用）、`TRHA_MAX_OUTPUT_TOKENS`（输出上限，
默认 128k）、`TRHA_WORKSPACE`（工具工作区）、`TRHA_PRICE_INPUT/CACHED/OUTPUT`
（每百万 token 价格；不配 `/api/usage-stats` 显示 `—`，不编数字）。

**思考模式（thinking）**：带 `tool_calls` 的 assistant 轮次必须把
`reasoning_content` 回传，否则 provider 直接 400。`ChatTurn.ctReasoning` 承接它，
流式 `delta.reasoning_content` 累积后写入 `ChatAssistantThought`，scheduler 存回历史。
这是多轮工具调用能继续的前提，不是可选的「优化」。

**流式用量**：请求带 `stream_options.include_usage`，内核把末帧 `usage`（含
cache hit/miss）透传给 scheduler，所以流式会话也能记账。

**工具**：模型可见目录与执行器同源于 `Server/toolCatalog.ts`，名字对齐
deepseek-harness（`bash/read/write/edit/glob/grep/append_file`，旧的 `*_file` 为别名）。
工具轮数默认**不设上限**，只对「同一调用连续重复」判停。

### 3.7 LLM Adapter (`LLM.Adapter`)

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
4. **Phase 4**: 实现存储后端 (JSON/SQLite) —— ✅ 已建成（`trha-infra`；会话持久化两层：编排层对话在 `stateStore.ts`，内核 checkpoint + 事件日志在 `Infrastructure.Storage.SessionStore`）
5. **Phase 5**: 开发 Desktop/Web 前端 —— Desktop 🟡（Electron + React，**不是本文 §4.3 写的 GTK/Qt**；linux deb 已验，win/mac 与实机启动未验）；Web ❌ 空壳

> 另注：本文 §4.3 的 `trha-desktop（GTK/Qt）` 与 §4.4 的 `trha-web（Warp）` **均非现状** ——
> Desktop 是 Electron + React，Web 是 React + Vite。真实前端在 `packages/app/{Desktop,Web}`，
> 不在 `src/Presentation/**`（该层从未参与编译，见 `presentation-layer.md` 头部标注）。