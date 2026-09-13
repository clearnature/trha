# trha 能力缝与核心服务（capability-seams）

> 对齐 deepseek-harness `docs/architecture.md` 的 Capability seams 一节：能力缝 =
> 注册点（`ctx.<key>` 服务 / 事件 / 目录），并附「加 X → 机制」速查表。
> 每一行机制均已在本仓库实现（T8 验收：grep 抽查存在）。

## 服务注册表（编排层 `packages/scheduler`）

| `ctx` 键 | 服务 | capabilities | 位置 |
|---|---|---|---|
| `ctx.events` | EventEmitter | `events:listen`, `events:emit` | `src/Server/index.ts` |
| `ctx.bridge` | HaskellBridge（内核 OpenAI 端点）| `model:query`, `sessions:list` | 同上 |
| `ctx.pluginManager` | PluginManager（自管理）| `plugins:register` | 同上 |
| `ctx.tools` | { list, execute }（宿主工具）| `tools:list`, `tools:execute` | 同上 |
| `ctx.sessions` | 会话存储视图（Map 只读快照）| `sessions:get` | 同上（T9）|

## 事件面（详见 `docs/architecture/event-matrix.md`）

`agent:message` / `agent:plan` / `agent:decision` / `tool:update` / `agent:model-request` / `session:created` / `session:deleted`
+ 插件分派：`ctx.on`（广播）、`ctx.waterfall`（改写）、`ctx.bail`（短路）、`ctx.parallel`、`ctx.serial`。

## 加 X → 机制（速查表，全部已实现）

| 目标 | 机制 | 落点（验证 grep）|
|---|---|---|
| 加一个模型提供方 | 改编排 `haskellHost/haskellPort`（内核为 OpenAI 兼容端点）；或内核侧注册 `LLMAdapter` | `Server/index.ts` HaskellBridge 构造 |
| 加模型面工具 | 在 `toolCatalog` 增条目（schema 单一来源）| `src/Server/toolCatalog.ts` |
| 改写/注入工具集 | `ctx.waterfall('agent:tools', …)` | `runStep` `runWaterfall('agent:tools')` |
| 整体拦截一步（审批/短路）| `ctx.bail('agent:step:before', …)` 返回回复 | `runStep` `runBail` |
| 观察模型请求 | `ctx.on('agent:model-request')`（模型可见即记录）| `runStep` emit；`Core.Transcript` `model-request` |
| 读工具/服务能力 | `ctx.service('tools' \| 'events' …)`（按键不 import）| `PluginManager.service` |
| 加会话持久状态 | `Core.Transcript`：新增 `EventKind` + `eventRegistry` 行 | `packages/app/CLI/Core/Transcript.hs` |
| 加本地 slash 命令 | `slashRegistry` 增 `SlashCommand` + `parseCommand` 分支 | `UI/Commands/Registry.hs` |
| 加宿主工具执行/沙箱 | `executeTool` 分支 + `toolGuard.confineWritePath`（symlink 安全）| `toolGuard.ts` |
| 插件目录热加载 | `pluginsDir` + `startPluginWatcher`（`watchPlugins` 默认开）| `src/Plugins/watcher.ts` |

## 不在本架构（如实标注，勿照搬）
- `ctx.fs`/`ctx.shell`/`ctx.terminals`/`ctx.jobs`/`ctx.webhookRuntime`/web 客户端节点：trha 无这些能力缝；
  将来若引入，按本表风格补注册点与机制行。
