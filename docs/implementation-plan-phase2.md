# Phase 2 实施规划（L1 垂直切片）— 修订版

**基线**: docs/implementation-plan-cli-tui.md（原 Phase 2 S1-S3）
**日期**: 2026-09-04（北京时间）
**触发**: Phase 2 启动前拓扑扫描发现**三端协议从未闭环**（阻塞性前置 S0）。

---

## 0. 拓扑扫描发现（2026-09 实测）

| 端 | 默认端口 | 对话路由（实测） | 备注 |
|---|---|---|---|
| CLI/TUI 外壳（packages/app/CLI） | **3000** | `/api/sessions`、`/api/sessions/{id}/messages`、`/api/agents/{id}`、`/api/models`… | `Bridge/Scheduler.hs` 硬编码路径 |
| TS 编排 scheduler（packages/scheduler） | **3456** | `/api/session/start`、`/api/agent/step`、`/api/sessions`(GET)、`/api/session/:id`、`/api/events/:sessionId`(SSE)、`/v1/*` | 桥接 Haskell 内核 **8080** |
| Haskell 内核 API.Server（src） | 调用方指定 | `/session/start`、`/agent/step`、`/v1/*`(±stream) | 无 `/api/sessions/{id}/messages` |

**结论**：CLI 的 `Bridge.Scheduler` 路径/响应形状与 TS、Haskell 两端**均不完全匹配**（单复数路由、`{reply}` vs `{response:StreamChunk}`、session 对象 vs 字符串数组、无 DELETE、无 messages 端点）——CLI/TUI 自完成以来从未真正连通服务端（这也解释了 transcript 端到端无法验证的根因）。SSE 事件流仅在 TS 侧雏形存在。

**架构意图**（README + Bridge 命名 + docs/pi-integration）：外壳(CLI/TUI/桌面/Web) → TS 编排层 → Haskell 内核；TS 侧 `/api/events/:sessionId` SSE 是共享事件流的正确载体。

---

## S0 — 协议闭环（阻塞性前置，Phase 2 第一件事）

让 CLI/TUI 第一次真正连通编排层。两种拓扑候选（决策点，见评审）：

- **方案 A（推荐）CLI ↔ TS 对齐**：按 TS 契约重写 `Bridge.Scheduler` 的路径与解析（session/start、agent/step、sessions GET、对象数组取 id）；TS 补 `DELETE /api/session/:id` 与（如需）`GET /api/session/:id/messages`；CLI 默认端口对齐 3456；端到端冒烟脚本（起 TS + stub Haskell 或内核）。
  - 符合编排架构、SSE 事件流可复用、桌面/Web 三端共享同一契约
  - 代价：TS 服务端需跑通（npm + bridge 需要 Haskell 8080；可先用 mock/stub）
- **方案 B CLI ↔ Haskell 内核直连**：内核 API.Server 补 `/api/sessions` CRUD + messages（servant 增量）；CLI 直连内核，TS 编排退出对话路径。违背既有编排设计，不推荐。
- **方案 C 双后端**：CLI 配置选择后端。灵活性最高、测试面翻倍，现阶段不必要。

**S0 验收**：CLI `cli` 模式真实会话（连接可运行服务端）跑通 user→assistant 往返；transcript 端到端落盘；hspec/TS 契约测试双绿。

---

## S1 — plan/approval 垂直切片（S0 之后）

**最小真实闭环形态**（不重写内核 LLM 循环）：
1. TS 编排层：`POST /api/agent/step` 支持会话 `mode=plan`（或 body `{requireApproval}`）→ 先返回 `{status:"awaiting_approval", pending:{preview}}` 不执行；`POST /api/session/:id/decision {approve:true|false, note?}` 后真正执行并返回 reply；状态 `pendingApproval` 与会话一起存（可 GET）。
2. CLI/TUI：plan 请求 → UI 显示 **PlanCard**（对照 Reasonix `plan_decision.go`：标题/摘要/approve/deny 键位）；approve/deny → POST decision → 继续流式显示 reply。
3. 事件：TS SSE `agent:message` 扩展 plan 状态事件；TUI 可选订阅（v1 用同步 decision 响应即可）。

**验收**：TS 契约测试（awaiting→decision→reply 状态机）；CLI 冒烟（起 TS 假内核）；TUI PlanCard 人工/脚本验证；transcript 记录 decision。

内核级 agent 内 ask（LLM 途中向宿主请求决策）依赖内核 agent loop 状态机扩展，属 Phase 3 深化，不在 S1 承诺范围。

---

## S2 — tool 事件详情（切片）

TS SSE 事件扩展 `tool` 事件（名称/参数/状态/耗时）；内核 `StreamChunk` 的 tool 事件经编排层透传；TUI ToolCard 展示状态与耗时；transcript 记录完整事件。

## S3 — resume（切片）

CLI 本地 transcript 索引 + TS `/api/sessions` 列表 → `resume` picker 恢复会话上下文（回放历史 + 继续）。

---

## 决策请求

1. 闭环拓扑：A / B / C？（推荐 A）
2. S1 形态确认：编排层 approval 门 + PlanCard（推荐） vs 直接深挖内核 agent ask 状态机？
