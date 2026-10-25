# trha 外壳↔编排层 共享协议总账（Phase 3 三端基线）

**日期**: 2026-09-05（北京时间）
**层**: 外壳（CLI/TUI/桌面/Web） ↔ TS 编排层（packages/scheduler，默认 :3456，Bearer token）
**文档依据**: 已实现代码（S0-S2）——任何新增端按此契约接入；任何改动须同步本表与对应契约测试。

---

## 1. 传输与认证
- HTTP/1.1 JSON（Content-Type: application/json）+ SSE（text/event-stream）长连
- 认证：`Authorization: Bearer <token>`（缺省 `dev-token`/env `TRHA_TOKEN`）；`/health` 与 `/v1/*` 豁免
- 错误形态：`{"error": "..."}` + 非 2xx（401/404/400/500）

## 2. 端点清单
| 方法/路径 | 请求 | 成功响应 | 契约测试 |
|---|---|---|---|
| GET /health | – | `{status:"ok",version,modes[]}` | CLI Bridge healthCheck |
| POST /api/session/start | `{mode}` | `{sessionId, mode}` | vitest index |
| GET /api/sessions | – | `[{id,mode,messages[],createdAt}]` | CLI listSessions |
| GET /api/session/:id | – | session 对象 | – |
| GET /api/session/:id/messages | – | `{messages:[{role,content}]}` | CLI getMessages |
| DELETE /api/session/:id | – | `{ok,sessionId}` | CLI deleteSession |
| POST /api/agent/step | `{sessionId,message,requireApproval?}` | `{reply,messages,mode}` 或 `{status:"awaiting_approval",pending:{message},mode}` | vitest; CLI sendMessage/planStep |
| POST /api/session/:id/decision | `{approve:bool}` | `{status:"approved",reply,…}` 或 `{status:"denied",mode}`；无挂起→400 | vitest S1; CLI approve/denyPlan |
| POST /api/session/:id/interrupt | `{}` | `{aborted:bool}`；空闲会话返回 `false` 且不置标志 | vitest interrupt; CLI interruptSession |
| GET /api/models | – | `[{name,description,contextSize}]` | CLI listModels |
| GET /api/plugins | – | `[{name,version,description}]`（运行时已注册插件） | vitest plugins-runtime |
| POST /api/plugins | `{name,version,description}`（宣告型，无钩子） | 201 `{ok,name}`；重复 409 | vitest plugins-dynamic |
| DELETE /api/plugins/:name | – | 200 `{ok,name}`；不存在 404 | vitest plugins-dynamic |
| GET /api/events/:sessionId | –(SSE) | data 帧（见 §3） | vitest tool-events |
| GET /v1/models · /v1/chat/completions(±stream) · /v1/messages(±stream) · /v1/responses(±stream) | OpenAI/Anthropic/Responses | 标准协议 | vitest protocols |

> **多步计划的端点**（同为转发）：`POST/GET /api/session/:id/plan`、
> `POST /api/session/:id/step-result`，以及 `POST /api/session/:id/decision`
> 带 `{action: "approve"|"skip"|"reject"|"abandon"}` 时走计划分支（不带 `action`
> 仍是原单命令闸门的 `{approve:bool}`）。响应体在内核返回之上补 `mode`。
>
> **审批闸门的事实源在内核**：`requireApproval` 与 `decision` 两个路由会把请求
> 转给内核 `/session/:id/approval` 与 `/session/:id/decision`（内核持有
> `awaiting_approval` 状态、做屏障、并落盘跨重启）。内核不可达时编排层降级为本地
> `pendingApproval`，上表响应形状不变。详见 `docs/architecture/architecture.md` §3.3。
>
> **中断语义**：`interrupt` 置会话的 `abortRequested`，工具循环在**轮次之间**检查并
> 以 `(interrupted)` 收尾；因此它只能停在下一轮边界，不能打断正在进行的单次模型
> 生成。空闲会话拒绝置标志（否则会中止下一轮），且每轮结束（`finally`）都会清标志，
> 迟到的中断不会泄漏到后续轮次。三个外壳共用该语义。

## 3. SSE 事件帧（data: JSON，按 sessionId 过滤）
| event 语义 | 载荷（字段） | CLI 类型 |
|---|---|---|
| 消息 | `{sessionId,role:"user"\|"assistant",content}` | –（回放/日志用） |
| 计划挂起 | `{sessionId,status:"awaiting_approval",message}` | PlanSubmit |
| 决策 | `{sessionId,approve:bool}` | PlanVerdict |
| 工具生命周期 | `{sessionId,name,args?,status:"running"\|"succeeded"\|"failed",error?,durationMs?,output?}`（`output` 仅 succeeded 携带，内核尾部预览：末 12 行 ≤2KiB，供 TUI 工具卡展开态；可选字段，旧外壳忽略） | ToolEvent（Core.Types From/ToJSON roundtrip 测试） |

## 4. 本地外壳数据（~/.trha）
| 项 | 说明 |
|---|---|
| settings.yaml（0600，分层：CLI args > ./项目 > ~/ 用户 > 默认） | host/port/model/token/maxTokens/timeout/retries/verbose/theme |
| sessions/<sid>/transcript.jsonl | jsonl 事件：session/user/assistant/tool(+status,error,durationMs)/done/error（向后兼容扩展字段） |
| history | haskeline 历史 |

## 5. 一致性保障（改动必须同步）
1. TS 类型（Server/index.ts ToolEvent 等）↔ CLI `Core.Types`
2. vitest 契约 ↔ hspec 解码测试（同一 JSON 双向 roundtrip）
3. 双 cabal other-modules 同步（root trha.cabal = packages/app/CLI/trha-cli.cabal）
4. 桌面/Web 新客户端按 §2/§3 实现，仅复用协议（不复制 CLI 内部实现）

## 6. 已知限制（协议面）
- 编排层会话为内存态（重启丢失）；CLI 本地 transcript 可回放不可续（服务端无该会话时提示）
- `agent/step` 同步返回聚合 reply；逐 token 流式由 /v1/*stream 提供（外壳未接入）
- 工具事件为 demo 注入（真实内核工具执行属 Phase 3 内核深化）
