# trha agent 生命周期（agent-lifecycle）

> 对齐 deepseek-harness `docs/agent-lifecycle.md`：一次 step（消息）在 trha 中如何
> 展开为多个模型轮次（round）+ 工具执行，每个阶段产生哪些可观测事件/落盘记录。
> 事件全集见 `docs/architecture/event-matrix.md`。

## Turn = 一次 `/api/agent/step`（一个用户消息 → 一个最终回复）

```
用户 step(message)
 ├─ [拦截] plugins.runBail('agent:step:before', message)
 │     非 null → 直接作为回复返回（不入模型）
 ├─ 会话记 user（transcript user + events agent:message user）
 ├─ round 循环（≤ MAX_TOOL_ROUNDS=5）：
 │    ├─ tools = ctx.tools.list() → waterfall('agent:tools')（插件可改写）
 │    ├─ [模型可见即记录] events emit agent:model-request {round,messageCount,toolCount}
 │    ├─ bridge.queryModel(messages, tools)          ← 每轮一次模型调用
 │    ├─ 有 tool_calls → executeTool（toolGuard 沙箱/限长）→
 │    │     tool:update 事件(running→succeeded) + transcript tool
 │    └─ 无 tool_calls → 文本=回合结束
 └─ 记 assistant（transcript assistant + agent:message assistant）
    + usage（transcript done）→ EvDone → bell（若 configBell）
```

## 生命周期对照

| deepseek 概念 | trha 对应 |
|---|---|
| Agent inbox / request | `/api/agent/step` 消息入口 + `agent:step:before` bail |
| Step（一次模型请求）| runStep 内一次 `queryModel`（round）|
| Turn | 一个 step 的整体（多 round 直到文本回复）|
| 工具执行管线 | `executeTool`（confineWritePath 沙箱、limitOutput、tool:update）|
| 审批暂停 | `agent:plan`(awaiting) → `/approve|deny` → `agent:decision` |
| 会话生命周期 | `/api/session/start→delete` + `session:created/deleted` + transcript `session` |
| 模型-可见-即记录 | `agent:model-request` 事件 + transcript `model-request`（T3）|
| 超轮终止 | MAX_TOOL_ROUNDS 后强制文本回复（`agent:message` assistant 含 exhausted 语义）|

## 遥测缺口（诚实）
- 内核（Haskell）侧无 lifecycle 事件——本表覆盖编排+CLI 两层的可观测面；
  内核 `API.Server` 的 HTTP 请求日志未纳入事件矩阵。
