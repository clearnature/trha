# 计划：Phase2 S2（tool 事件详情）+ S3（resume）原子分解

**Planner 依据**: team-planner 职能 + fable5 流程；参考 /data/work/functional-programming/hs/haskell-agent
**日期**: 2026-09-05（北京时间）
**状态**: 待执行（team-executor 按此实施，team-discipline 审查）

---

## 1. 拓扑扫描

### S2（tool 事件详情）相关文件
| 层 | 文件 | 现况 |
|---|---|---|
| TS 编排 | `packages/scheduler/src/Server/index.ts` | `runStep` 同步聚合 reply；**无工具事件**；SSE `/api/events/:sessionId` 已过滤 sessionId |
| CLI 纯层 | `UI/Render/ToolCard.hs` | 已有 `ToolStatus(Running/Succeeded/Failed)` + `toolCardLines`（72 列截断）——布局就绪，**缺状态着色/耗时/来源数据** |
| CLI UI | `UI/Brick.hs` | `PendingMsg.pmTools::[ToolInv]`、`messageBody` tool 卡渲染、`EvPlan/EvVerdict` 先例可仿 |
| CLI 桥 | `Bridge/Scheduler.hs` | 无 tool 事件订阅 |
| CLI 转录 | `Core/Transcript.hs` | `recordTool sid name args`——**缺状态/耗时字段** |
| 内核 | `src/LLM` StreamChunk | 有 `ChunkToolCall ToolName [Text]`（无状态/耗时）；CLI Core.Types 同名 |

参考（haskell-agent）：`Agent.Tools.Types` 的 `ToolCall/ToolCallResult`（结构化调用+结果）——建议把"调用"与"结果（状态/耗时/输出摘要）"分开建模。

### S3（resume）相关文件
| 文件 | 现况 |
|---|---|
| `Core/Transcript.hs` | `loadTranscript` 按行读 jsonl（坏行跳过）——**无索引/元数据查询**（只按 sid 读全量） |
| TS Server | sessions 内存 Map，重启即失；`/api/sessions` 返回数组 |
| CLI UI | `/sessions`（服务端列表）；无 resume/回放 |
| 参考 | haskell-agent `Agent.CLI.Transcript`：`projectTranscriptTurn`（**回放与实时同一渲染规则**，UiBlock 投影）；SessionMeta/SessionTurn 类型 |

---

## 2. 多路径推演

### S2 实现路径
- **方案 A：编排层事件驱动（推荐）**。TS 把工具执行建模为独立资源：`ToolExecution {id, sessionId, name, args, status, startedAt, finishedAt?, outputTruncated?}`；`runStep` 执行中真实工具调用时推 SSE `tool:update`（每次状态变化）；CLI 通过 SSE `/api/events/:sessionId` 订阅并驱动 ToolCard。
  - 复杂度：中高（SSE 客户端 + 事件状态机）
  - 可维护性：高——与"外壳↔编排解耦 + 三端共享事件"一致；桌面/Web 可复用
  - 风险：当前内核无真实工具执行（LLM 网关），端到端只能以 TS 模拟工具（例如 fallback 模式注入一次工具事件）验证
- **方案 B：同步扩展 agent/step 响应**（`{reply, tools:[{...}]}` 数组随 reply 返回，无 SSE）。复杂度低，但丢失"进行中"状态且与 SSE 事件架构分叉。
- **结论：A**。但**切片一先做契约与数据模型（含模拟注入），切片二再做 CLI SSE 订阅**——避免一次跨三层。

### S3 实现路径
- **方案 A：本地为主（推荐）**。resume = 本地 transcript 索引 + 回放（内核会话在服务端，重连后从 transcript 恢复上下文显示；参考 haskell-agent 回放/实时同渲染规则）。索引：扫描 `~/.trha/sessions/*/transcript.jsonl` 首/尾事件构建 `SessionSummary {id, title(首条 user 截断), lastTs, turns, model}`。UI：`/resume` picker。
  - 复杂度：低-中；离线可用；不依赖服务端会话保活
  - 风险：transcript 只记 CLI 侧数据（服务端会话消息以 CLI 视角为准，够用）
- **方案 B：服务端会话恢复**（TS 会话持久化 + resume 端点）。TS 目前内存 Map，需存储后端——扩大切片，编排层尚未有持久化设计。
- **结论：A**（本地索引先行，TS 持久化列为后续独立项）。

---

## 3. 任务分解（原子，每项 ≤1 人日，按序）

### S2（依赖顺序执行）
- [ ] **S2-A1 事件/数据模型**：`Core.Types` 增 `ToolEvent { teId, teTool ToolInv, teStatus ToolStatus, teDurationMs Maybe Int }`（ToolInv 已有）；TS 侧类型对齐。→ 验证: CLI hspec（构造/JSON roundtrip 或纯构造）+ TS tsc
- [ ] **S2-A2 TS 模拟工具注入**：`runStep` fallback 分支（或标准 mode）在生成回复前推送 `tool:update` SSE（bash 示例：status running→succeeded + duration）；事件带 sessionId。→ 验证: vitest 订阅/事件契约 + tsc
- [ ] **S2-A3 CLI Bridge SSE 订阅**：新增 `subscribeSessionEvents :: SchedulerBridge -> SessionId -> (ToolEvent -> IO ()) -> IO (IO ())`（HTTP 长连解析 `data:` 行；Token auth）。→ 验证: 单元（用假 HTTP？IO 层——冒烟级）；起 TS 实测事件到达
- [ ] **S2-A4 ToolCard 状态渲染**：ToolCard 增状态色/耗时行（ToolStatus→着色映射在 UI/Theme 加 role 或就地）；`messageBody` tool 卡按状态着色；pending 工具事件驱动追加 ToolInv+状态。→ 验证: hspec（toolCardLines 带状态 golden）+ 构建
- [ ] **S2-A5 转录补全**：`recordTool` 增可选 status/duration 字段（jsonl 事件向后兼容：新字段可选）。→ 验证: hspec（旧行解析不坏 + 新字段）
- [ ] **S2-A6 端到端冒烟**：起 TS（模拟工具事件）→ CLI 收到事件 → TUI/文本状态更新。→ 验证: 冒烟输出含 `[tool] bash` + ✓/耗时

### S3（依赖顺序执行；与 S2 独立可并行开发纯层）
- [ ] **S3-A1 Transcript 索引（纯）**：`Core.Transcript` 增 `SessionSummary` 与 `listLocalSessions :: IO [SessionSummary]`（扫 sessions/*/transcript.jsonl 首尾行）。→ 验证: hspec（构造含 session/user/assistant 的临时 jsonl → 摘要正确；空目录/坏文件容错）
- [ ] **S3-A2 回放渲染（纯）**：`renderTranscript :: [Value] -> [MdBlock]/文本` 或按 role 输出（参考 haskell-agent 回放=实时同规则；v1 用 parseMarkdown 渲染 user/assistant、tool 卡）。→ 验证: hspec golden
- [ ] **S3-A3 REPL `/resume`**：picker 或编号列表显示本地会话摘要 → 选择 → 回放 + 设 sessionRef（服务端 sid 一致时继续对话；缺失则提示）。→ 验证: 冒烟（构造 transcript → /resume 列出 → 选择回放）
- [ ] **S3-A4 TUI resume**：`/resume` 走既有 Picker 基建（候选=本地摘要）；选择后消息区载入回放并设置会话。→ 验证: 构建 + TUI 冒烟受限（无 TTY 标记）
- [ ] **S3-A5 双端命令注册**：`/resume` 入 Registry（picker/补全自动），REPL/TUI help 文本更新。→ 验证: hspec 注册表断言 + help 冒烟

### Merge 后整体回归（固定序）
- [ ] **R1** CLI `cabal test`（既有 78 + 新增全绿）
- [ ] **R2** 根 exe 与 CLI 子包双 `cabal build`
- [ ] **R3** TS `npx tsc && vitest run`
- [ ] **R4** 端到端冒烟（起 TS：普通消息 + tool 事件 + /resume 回放）
- [ ] **R5** cabal other-modules 一致性核对（root 与子包）

---

## 4. 对抗自检（薄弱环节）
- **S2 SSE 是长连接**：CLI REPL（haskeline）与 TUI（brick）都需要非阻塞接收——TUI 有 BChan+async 先例；REPL 需后台线程。**薄弱**：REPL 下 SSE 线程生命周期与退出（/quit 时泄漏连接）。缓解：subscribe 返回取消句柄，命令退出时调用；先只在 TUI 接 SSE，REPL 用同步 tools 数组兜底（降级不阻塞）。
- **ToolEvent 状态驱动时机**：fallback 无真工具——A2 的"模拟注入"可能制造假象。缓解：标注 demo-only 注入点，真实工具经内核时替换（Phase 3）。
- **S3 摘要标题**：取首条 user 消息截断，可能为空（纯 tool 会话）——容错回退 "Untitled <id>"。
- **时间窗口**：TS 会话在服务端、CLI 本地 transcript 的 sid 一致性依赖会话仍在服务端；服务端重启后 resume 只能回放不能继续——需在 UI 提示"会话不可继续（服务端无此会话）"。已在 S3-A3 标注。
- **依赖**：S2 与 S3 纯层可并行；SSE/TS 改动集中在 S2，避免与 S3 的 UI 改动同文件冲突（S3 触碰 UI.Brick 的 /resume；S2 触碰 messageBody——不同函数，风险低）。

## 5. 缓存/纪律检查点
- 不涉及 Reasonix 发送侧字节/缓存前缀；遵循：纯层可单测、双 cabal 同步、TRHA_TOKEN 命名、不删代码、TS 契约测试、端到端冒烟证据。
