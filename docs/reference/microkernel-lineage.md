# 微内核谱系：Cordis / Yi / Reasonix / trha

> **日期**：2026-10-27（北京时间）
> **问题**：trha 的「微内核」到底来自哪里？`deepseek-harness`、`yi-editor`、`Reasonix` 各自提供了什么？
> **方法**：读三个参考实现的源码/文档，再对照本仓 `archive/haskell-plugin/Core/Plugin/*` 与 scheduler 的插件层。

---

## 0. 一句话

| 来源 | 提供的是 | 对应到 trha |
|---|---|---|
| **deepseek-harness（Cordis）** | **概念**：一切皆插件、类型化事件、可逆副作用、capability seam | `Core.Plugin.Free` 的 `ProvideEffect` / `Disposer`；scheduler 的 `ctx.service/on/waterfall/bail` |
| **Yi（`dynamic-state`）** | **Haskell 手法**：`HashMap ConcreteTypeRep Dynamic` 的类型索引可扩展状态 | `PluginF` 里的 `RegisterService String Dynamic` / `SubscribeEvent String (Dynamic -> IO ())` |
| **Reasonix（Extension Protocol v2）** | **进程外模型**：sidecar + NDJSON JSON-RPC + manifest 校验 | MCP / LSP（进程外）；内核插件层**没有**采用 |

**结论**：trha 的概念取自 dsh，手法取自 Yi，进程外模型参考 Reasonix；
但三者**没有统一到一个模型**——`Core.Plugin` 在生产路径上零引用，实际扩展点在 scheduler。

---

## 1. deepseek-harness / Cordis —— 概念来源

来自 `/home/yanli/work/deepseek-harness/docs/architecture.md`：

- **一切皆插件**：模型适配器、工具注册表、会话日志、agent loop 都是插件，可被配置替换。
- **profile / bundle**：一次运行 = 启动时按序组合的插件树；patch 按 row id 替换配置。
- **capability seam**：Service Definition / Service Provider / Consumer 三角色。
- **可逆副作用**：注册即 effect，插件卸载时回滚。

trha 的对应物：

```haskell
data PluginF next
  = RegisterService String Dynamic next
  | SubscribeEvent String (Dynamic -> IO ()) next
  | ProvideEffect (IO (IO ())) next      -- 注册时拿 cleanup，卸载时执行
  | forall a. WithContext (IO a) (a -> next)
```

`Disposer` 用 `Semigroup` 串联、`execPlugin` 按 LIFO 返回 cleanup——这就是 Cordis `ctx.effect` 的 Haskell 版本。

**差异**：dsh 的插件树是**运行时事实**（`dsh --dump-config` 能看到、patch 能替换）；
trha 的 `Core.Plugin` 没有运行时挂载点，也没有任何生产代码调用它（仅 `test/PluginSpec.hs`）。

---

## 2. Yi / dynamic-state —— Haskell 实现手法

Yi 是「一组用来拼装编辑器的库」（`/data/training/cli/yi-editor/yi/README.md`）：

- **Frontends**：vty（终端）/ pango（图形），只负责渲染与事件。
- **Actions**：三层 monad DSL —— `BufferM`（单 buffer）、`EditorM`（多 buffer/窗口）、`YiM`（IO）。
- **Keymaps**：vim-like / emacs-like，可替换。
- **Core**：不依赖具体前端。

`dynamic-state` 解决的问题是「扩展怎么在共享状态里存自己的东西」：

```haskell
-- /data/training/cli/yi-editor/dynamic-state/src/Data/DynamicState.hs
newtype DynamicState = DynamicState { unDynamicState :: HashMap ConcreteTypeRep Dynamic }

getDyn :: forall a. Typeable a => DynamicState -> Maybe a
setDyn :: forall a. Typeable a => DynamicState -> a -> DynamicState
_dyn   :: (Typeable a) => a -> ...          -- 带默认值的 lens
```

- 以**类型的具体表示**（`ConcreteTypeRep`）为键，而不是字符串名字。
- core 不需要知道扩展的具体类型；扩展按自己的类型 `getDyn`/`setDyn`。
- 这是「可扩展状态」在 Haskell 里最省事的做法，也是 Yi 能做成库集合的关键。

trha 的对应物：

```haskell
data Env = Env
  { envServices :: IORef (Map.Map String Dynamic)      -- 字符串键
  , envEvents   :: IORef (Map.Map String [Dynamic -> IO ()])
  , envEffects  :: IORef [IO ()]
  }
```

**差异**：Yi 用**类型**做键、一个 `DynamicState` 容器；trha 用**字符串**做键、三个 `IORef` 分开。
后者的直接后果是：服务名拼错只会在运行时变成 `Nothing`，而 Yi 的写法是编译期类型约束。

---

## 3. Reasonix / Extension Protocol v2 —— 进程外模型

来自 `/home/yanli/work/DeepSeek-Reasonix/docs/EXTENSION_PROTOCOL.md`（reviewed 2026-09-29）：

- **sidecar**：host 以 exec 形式 spawn 子进程，扩展**不链接进宿主二进制**。
- **传输**：严格 JSON-RPC 2.0 over NDJSON（每行一个完整对象）；8 MiB 帧上限；超限即 `frame_too_large`。
- **生命周期**：先 `extension/initialize`，宿主发 manifest 期望（intercepts / replaces / providers / UI actions）；
  扩展回的声明必须是 manifest 的**子集**，协议 major 必须精确匹配。
- **资源**：一个运行时世代最多 4 个 sidecar 并行，共享 30 秒启动预算。
- **失败隔离**：sidecar 崩溃不影响宿主（与 dsh 的进程内插件相反）。

Reasonix 另一条线是 **Agent compositions**（`docs/AGENT_COMPOSITIONS.md`）：
persona + tools/skills/MCP/extensions/hooks 组成一个 preset，**不加载 dsh 的 Cordis 插件**——
它明确选择了「运行期组合」而不是「构建期插件树」。

trha 的对应物：

- **进程外**：`Server/mcp.ts`（MCP server）、`Server/lsp.ts`（LSP）——有子进程与协议。
- **进程内**：scheduler `Plugins/{loader,Plugin,Registry,watcher}.ts`——Cordis 式 API，但可热加载（`watcher.ts`）。
- **内核**：`Core.Plugin` 有实现、无挂载。

**差异**：Reasonix 把「进程外」做成了**统一协议**（所有扩展走同一套 JSON-RPC + manifest）；
trha 是「MCP 一套、LSP 一套、scheduler 插件又一套」，没有统一。

---

## 3.5 Haskell 侧参考：haskell-agent / langchain-hs / tricorder

> 位置：`/data/work/functional-programming/hs`（2026-10-27 读）
> 这一组证明：**Haskell 本身足以写完整 agent harness**；trha 的多语言拆分是分工选择，不是语言限制。

### haskell-agent（digitallyinduced）

- **30+ 包按能力拆分**：
  - `agent-core`：provider-neutral 的 loop / turn / tool dispatch / subagents / transport；
  - `agent-runtime`：`TurnEngine`、`Host`、`Providers/*`、`Session/*`、`Permission`；
  - `agent-runtime-daemon`：`TaskScheduler` / `Supervisor` / `Journal` / `Socket` / `Protocol`（本地 daemon）；
  - `agent-server`：HTTP API + PostgreSQL + 可重放 SSE；
  - provider 每 wire 一包：`agent-openai` / `agent-claude` / `agent-gemini` / `agent-xai` /
    `agent-openrouter` / `agent-responses` / `agent-codex-dialect` / `agent-grok-build-dialect`；
  - 工具与界面：`agent-tools`（含 code-mode）、`agent-mcp`、`agent-computer-use`、
    `agent-tui`、`agent-cli`、`agent-server-client`。
- **`agent-server`**（`docs/agent-server.md`）：`127.0.0.1:4096`、默认只允许当前目录、
  严格 `Host` 头、不开 CORS、OpenAPI 3.1、PostgreSQL 持久化、SSE 可重放；
  多租户模式每租户一个 gVisor 沙箱。
- **steering / queue**：运行中的 turn 可 steer 或排队（`/steer`、`/queue`）——
  与 trha scheduler 的 `/steer`、`/queue` 同型。
- **与 trha 的关系**：trha 的 `~/.haskell-agent` 初始化模式、TUI 交互与工具形状参考过它；
  但它**没有独立编排层**——runtime 是同一个 Haskell 进程，daemon 只是可选的本地 socket。

### langchain-hs

- `RunnableTree`（纯 AST pipeline）+ `StateGraph`（循环状态图）+ `langchain-hs-mcp` + OpenTelemetry；
  effect-polymorphic，provider 也是分包的（ollama / openai / gemini）。
- 与 trha 的对照：trha 用 Free monad 插件 + FSM；langchain-hs 用纯 AST 图 + 循环图。
  两者都在避免把控制流直接写进 IO。

### tricorder

- Haskell 开发工具：`tricorder` daemon（后台 build）+ `tricorder ui`（TUI）+
  `tricorder status`（CLI）+ `agent-plugins/{tricorder,tricorder-mcp}`。
- 与 trha 同构的点：**一个 daemon + 多客户端（socket）+ MCP 插件**；
  但它是 build 工具，不是 harness。

### 对 trha 的含义

| 维度 | haskell-agent | trha |
|---|---|---|
| 进程模型 | 单 Haskell 进程 + 可选 daemon/socket + 可选 HTTP server | Haskell 内核 + TS 编排 + 壳（3 段 2 跳） |
| 包结构 | 30+ 细包 | 5 个 library（共享 `src`）+ CLI 包 + TS |
| provider | 每 wire 一包 | 3 wire adapter + `ProviderRuntime` |
| 工具 | `agent-tools` + MCP + computer-use | scheduler 工具层 + MCP/LSP |
| 会话 | PostgreSQL / 本地 store | 内核 checkpoint + scheduler `stateStore` + CLI transcript |
| 沙箱 | gVisor（多租户） | `toolGuard` 写入围栏（无沙箱） |
| 多壳 | TUI / CLI / server / client | TUI / CLI / Desktop / Web |

**结论**：单语言可行（haskell-agent 为证）；trha 选择 TS 编排，是工具/插件生态与三壳共享的工程效率取舍，
**不是 Haskell 做不到**。

---

## 4. 四者对照

| 维度 | dsh / Cordis | Yi / dynamic-state | Reasonix v2 | trha 现状 |
|---|---|---|---|---|
| 扩展位置 | 进程内 | 进程内（库级） | **进程外 sidecar** | 两者都有，内核插件层未用 |
| 共享状态 | `ctx` 服务 | `DynamicState`（类型键） | 协议消息 | `Map String Dynamic`（字符串键，未挂载） |
| 可逆性 | `ctx.effect` | 无（纯状态） | sidecar 生命周期 | `Disposer` LIFO |
| 组合单位 | profile / bundle | cabal 包 + 配置 | extension manifest | scheduler `ctx` 插件 / MCP / LSP |
| 失败隔离 | 无（同进程） | 无 | 子进程崩溃隔离 | MCP/LSP 有；scheduler 插件无；内核插件无 |
| 运行期安装 | profile patch | 静态编译 | **manifest + spawn** | scheduler 热加载；内核无 |

---

## 5. trha 的实际落点（代码事实）

| 项 | 事实 | 证据 |
|---|---|---|
| `Core.Plugin` | **生产零引用**，仅 `test/PluginSpec.hs` 引用 | 全仓 `rg "Core\.Plugin"` |
| 真正的扩展面 | scheduler 的 Cordis 式 `ctx`（service/inject/waterfall/bail） | `docs/architecture/dsh-capability-seams.md` |
| 进程外能力 | MCP / LSP | `packages/scheduler/src/Server/{mcp,lsp}.ts` |
| 内核插件挂载点 | **不存在** | `startServer` 没有任何 plugin 参数 |

也就是说：

> 「微内核」在 trha 里是**概念来源**（dsh）＋**实现手法**（Yi），
> 但**不是当前的运行事实**——真正在用的是 scheduler 的插件层。

---

## 6. 建议（与既有评审 A3 对齐，不重复）

1. **二选一**：把 `Core.Plugin` 接到内核（真实挂载点），或归档它并改文档为「扩展点在 scheduler」。
2. **若要进程外统一**：参考 Reasonix v2 的 manifest + 子进程隔离，而不是继续给 MCP/LSP 各写一套特例。
3. **类型键 vs 字符串键**：若保留 Haskell 插件层，考虑采用 `ConcreteTypeRep` 式的类型键（Yi 的做法），
   否则拼错服务名只会在运行时报 `Nothing`。
4. **文档措辞**：`architecture.md` §1 的「微内核」应注明是**设计来源**，并指向本文；不要让它读起来像已实现的运行机制。

---

## 7. 核实命令

```bash
# Cordis 概念
sed -n 1,60p /home/yanli/work/deepseek-harness/docs/architecture.md

# Yi 的 DynamicState
sed -n 1,60p /data/training/cli/yi-editor/dynamic-state/src/Data/DynamicState.hs
sed -n 45,70p /data/training/cli/yi-editor/yi/README.md

# Reasonix v2
sed -n 1,60p /home/yanli/work/DeepSeek-Reasonix/docs/EXTENSION_PROTOCOL.md
rg -n "^#{2,3} " /home/yanli/work/DeepSeek-Reasonix/docs/AGENT_COMPOSITIONS.md

# trha 的插件层是否接线
rg -ln "Core\.Plugin" --glob '*.hs' --glob '!dist-newstyle' .
```

---

## 8. 本文核实不了的

- **Yi 的完整架构**只读了 README 与 `dynamic-state` 的核心模块；未审 `yi-core` 的 keymap/action 实现。
- **Reasonix v2 的运行时行为**未实测（只读协议文档）；sidecar 的失败隔离是文档声明。
- **dsh 的进程内插件树**只读了 `docs/architecture.md` 与 `capability-seams.md`，未跑其插件加载器。
