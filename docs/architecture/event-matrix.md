# trha 事件矩阵（event-matrix）

> 对齐 deepseek-harness `docs/event-producer-consumer.md`：每一事件的 producer（谁发出）、
> consumer（谁监听/消费）、持久化位置（是否落 transcript / SSE 转发）。
> 维护：改动事件时更新本表（新增行 + 更新 `EventKind` 注册表 / SSE 白名单）。

## 编排层事件（`packages/scheduler` EventEmitter）

| 事件 | Producer（代码点）| Consumer | SSE 转发 | 持久化 |
|---|---|---|---|---|
| `session:created` | `/api/session/start` | 插件 `ctx.on` | — | CLI transcript `session`（/new 侧）|
| `session:deleted` | `/api/session/delete` | 插件 | — | — |
| `agent:message` | `runStep`（user 入/assistant 出、拦截回、超轮）| SSE `/api/events/:sessionId`、插件 | ✅ | CLI transcript `user`/`assistant` |
| `agent:reasoning` | `runStep`（`queryModelStream` 的 reasoning 回调）| SSE、CLI（`EvNotice` → thinking 卡）| ✅ | —（只有 final 文本入 transcript）|
| `agent:model-request` | `runStep`（**每次** `queryModel` 前）| SSE、CLI（step 分隔行）、插件 | ✅ | CLI transcript `model-request` |
| `agent:context` | `runStep`（contextGovernor 改写前缀时）| SSE、CLI（compaction 卡）| ✅ | — |
| `agent:retry` | `runStep`（`withRetry` 退避前）| SSE、CLI（retry 行）| ✅ | — |
| `agent:plan` | `/api/agent/plan`（awaiting_approval）| SSE、CLI（EvPlan）| ✅ | CLI transcript（plan 决策流）|
| `agent:decision` | `/api/agent/approve|deny` | SSE、CLI（EvVerdict）| ✅ | — |
| `tool:update` | `runStep`（工具 running/succeeded）| SSE、CLI（EvTool→`tool` 卡）| ✅ | CLI transcript `tool`（running/succeeded）|

## CLI transcript 事件（`Core.Transcript`，事件注册表单一来源）

| type | Producer | Consumer / 用途 |
|---|---|---|
| `session` | `/new` CreateSession | 回放标题/会话摘要 |
| `user` | SendMessage 前 `recordUser` | 回放消息区 |
| `assistant` | ChunkDelta 聚合 | 回放 assistant 块 |
| `tool` | ToolEvent（running/succeeded/failed）| 工具卡回放 |
| `done` | ChunkDone（usage）| token 统计 |
| `error` | CLI 错误路径 | 回放错误行 |
| `model-request` | SendMessage 前置 `recordModelRequest` | 请求可重构（T3）|

## 协议约定

- **SSE 白名单**（`/api/events/:sessionId` 转发 4 事件）与事件注册表是两份列表——新增对外事件时二者都要加。
- **“模型可见即记录”**：编排中凡要发给模型的输入（messages/tools 变化）必须先产出可观测事件（`agent:model-request`），CLI 侧同步落 `model-request`，保证日志可重构一次请求。
- 插件监听：`ctx.on('agent:model-request'|…)` 挂载/释放均被 PluginManager 跟踪（releases）。
