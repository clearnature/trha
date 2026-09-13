# 内核真实工具执行 — 拓扑结论与方案（Phase 3 内核深化）

**日期**: 2026-09-05
**方法**: Fable 5 Step 1 实测扫描（本仓库三处 + 参考 haskell-agent）

## 1. 数据通路实测结论（不再是"未知"）

| 位置 | 现状（实测） | 结论 |
|---|---|---|
| `src/LLM/Adapter/Interface.hs` | `llmChat :: [Message] -> IO [StreamChunk]`；`Role = System\|User\|Assistant`；无 tools 参数 | **不支持 function calling** |
| `src/LLM/Providers/DeepSeek.hs` | 真实 HTTP；请求只 model/messages/stream；响应 `RespMessage{role,content}` 不解析 `tool_calls` | **无 function calling** |
| `src/API/Server.hs` `parseOpenAI` | 丢弃 `tools`；parseMsg 只 role/content | **不透传 tools** |
| `packages/scheduler/src/Bridge/Haskell.ts` | `queryModel` POST **`/api/query`**（内核 API.Server **无此端点**）；另有 /api/verify、/api/cache | **编排↔内核桥从未闭环**（与早期 CLI↔TS 失配同型） |

**推论**：真实工具执行 = 全链路扩展（消息模型 → provider → API 透传 → TS 桥改打内核真实端点 → 编排层 agent loop 执行工具并回填）。

## 2. 参考 haskell-agent 的结构要点（已抽查）
- `Agent.Tools.Types`：结构化 `ToolCall`/`ToolCallKind`/`ToolCallResult`（含状态/结果）
- `Agent.ToolDispatch`：`dispatchRegisteredToolCall` —— 工具注册表驱动执行
- 其 provider 消息模型支持 tool 角色消息回填（LLM 循环标准形态：user→assistant(tool_calls)→tool(结果)→assistant）

## 3. 方案（执行主体分叉）

### 方案 A — 编排层（TS）执行工具（推荐）
内核只扩展 **function-calling 消息协议**（K1-K3：消息模型/DeepSeek provider/API 透传，纯 Haskell 可测）；TS `runStep` 变 agent loop：带 tools 调内核 → 得 `tool_calls` → 编排层用已注册工具执行（宿主侧，安全/沙箱/凭据策略留在宿主）→ 结果以 tool 消息回填 → 再调内核，直至无 tool_calls（上限轮次）。SSE `tool:update` 与 PluginManager 工具实现可挂载。
- 复杂度：中高（两层都动）；可维护性：高（沿用 CLI↔TS↔内核分层 + 插件）；风险：内核 provider 无真 key 时以 mock 契约测试闭环

### 方案 B — 内核（Haskell）执行工具
内核 agent loop 内接 `Core.Tools` 注册表执行（文件/命令副作用）+ 沙箱/凭据内建。
- 复杂度：高（跨层+安全模型）；风险：绕过现有 TS 工具面，双工具注册表并存
- **不推荐现阶段**

## 4. 原子分解（方案 A）
- K1 内核消息模型：`Role`+Tool；Message 增 tool 字段；纯类型+JSON roundtrip（root hspec）
- K2 DeepSeek provider：请求带 `tools`、解析 `tool_calls`（含多候选内容合并）
- K3 API.Server `/v1/chat/completions`：透传 `tools`；响应含 `tool_calls`；/v1/agent/step 等价
- K4 TS 桥：改打内核 `/v1/chat/completions`（Bearer token），响应扩展 reply+tool_calls
- K5 TS agent loop：循环执行（内置最小工具：bash echo 白名单）→ 回填 → 上限轮次；SSE 事件保持
- K6 契约与端到端：vitest（stub 内核 OpenAI 响应）+ 三链集成（mock provider）+ CLI 冒烟

## 5. 依赖顺序
K1 → K2/K3（并行纯层）→ K4 → K5 → K6；每步测试先行（内核侧 root `trha-test` hspec 基建已存在）。
