# trha 架构对照审核（vs DeepSeek-Harness / Reasonix / opencode）

> **日期**：2026-10-27（北京时间）
> **性质**：**架构形状**的对照审核 —— 进程边界、职责归属、扩展点、真相源。
> **判据**：架构一致性（文档宣称 vs 实现）与可演进性；**不是**数学正确性（C1–C5），也**不重复**构建拓扑。
>
> **与既有两份的分工**：
>
> | 文档 | 回答的问题 | 判据 |
> |---|---|---|
> | `architecture/architecture-intended-vs-actual.md` | 项目**意图**与现状差在哪（D-1…D-9） | 数学/理论正确性 |
> | `reference/trha-architecture-review.md` | **构建拓扑**实测（S1–S6） | 工程可维护性 |
> | **本文** | **架构形状**与参考实现比，哪里不一致/难演进 | 架构一致性与可演进性 |
>
> 每条结论附代码位置或可复现命令；拿不出证据的进 §7「核实不了的」。

---

## 0. 一页结论

| # | 发现 | 严重度 | 参考实现的对照 | 证据 |
|---|---|---|---|---|
| **A1** | **会话真相有三份**：内核快照+事件日志、scheduler `stateStore`、CLI `transcript.jsonl`，没有任何一处被声明为权威 | 🔴 高 | dsh：session log 是**唯一**事实源，模型历史由 `deriveMessages()` 投影 | `Core/Session/Types.hs:97-109`、`stateStore.ts:25-51`、`Core/Transcript.hs:82-88` |
| **A2** | ~~**内层安全弱于外层**：scheduler 有 Bearer，内核无认证~~ **2026-10-27 已修复**：内核绑 `127.0.0.1` + loopback gate（Bearer token / Host / Origin / 非 JSON 写 415） | ✅ 已修复 | dsh 有 sandbox/approval seam；Reasonix 有 THS 可信执行 | `API/Security.hs`、`Core/KernelToken.ts`、`test/SecuritySpec.hs` |
| **A3** | **「微内核 / 一切皆插件」名实不符**：Haskell 插件层零引用，真正的扩展在 TS scheduler | 🟠 中高 | dsh：插件树是运行时事实（profiles/bundles 可组合） | `archive/haskell-plugin/Core/Plugin/*` 只被自身 import；`scheduler` 有 `ctx.service/inject/waterfall/bail` |
| **A4** | **内核职责与 2026-09 裁定冲突**：裁定「内核 = 无状态执行引擎」，实现里内核持有 FSM + 审批 + 持久化 | 🟠 中 | dsh：turn flow 与审批都在 loop/agent 层，内核无「第二权威」 | `Core/Session/Manager.hs:107-203`、`API/Server.hs:203-213` |
| **A5** | ~~**端口/配置漂移**：scheduler 默认内核端口 `8080`、CLI `serve` 默认 `3333`~~ **2026-10-27 已修复**：两端统一为内核 `19433` / scheduler `28433`；配置仍分三套 | ✅ 已修复 | dsh：config catalog + profile patch 单一来源 | `Server/index.ts`、`Core/Args.hs`、`cli.ts` |
| **A6** | 构建门禁失效（~13.6k 行 Haskell 在构建外） | 🔴 高 | 参考项目均为全量 CI | 见既有评审 S2；本文不重复 |
| **A7** | Web 壳是空壳（1.6k 行，不在 CI），而 scheduler 已托管 `/studio` | 🟡 中低 | opencode：web 是正式客户端 | `project-overview.md:1.1`、`Server/index.ts:502-622` |
| **A8** | 事件列表有两份（SSE 白名单 vs 事件注册表），新增对外事件需双改 | 🟡 低 | dsh：单一 event map + 代码内注册 | `architecture/event-matrix.md:36` |

**一句话**：三层边界（内核 / 编排 / 壳）本身是**成立的**——opencode 同样是 server + 多客户端；
trha 的问题不在「分层」，而在**同一事实被三层各存一份**、**内层没有安全边界**、**文档宣称的扩展机制与实际扩展点不是同一个**。

---

## 1. 参考架构速览

### 1.1 DeepSeek-Harness（dsh）—— 单进程 Cordis 插件树

- 一切都是插件：模型适配器、工具注册表、会话日志、agent loop 都在 shared context 里，可被配置替换。
- **profile / bundle**：一次运行 = 启动时按序组合的插件树；patch 按 row id 替换配置。
- **capability seam** 三角色：Service Definition / Service Provider / Consumer；换 provider 即换整个产品能力（如 `ctx.fs` 换成远端沙箱，Bash/PTY/LSP 一起搬走）。
- **会话日志是唯一事实源**：`deriveMessages()` 从 log 投影模型历史；「model-visible means logged」——任何模型可见输入必须先成为 session event。
- 扩展点有明确表（`docs/architecture.md` §Where new behavior goes），新增行为落在文档化的 event/seam 上。

### 1.2 Reasonix 2.x —— 单二进制、四壳同程序

- Go 单体，`internal/` 13 层，规模从 24k（base）到 172k（frontend）行。
- Desktop / CLI / Web / ACP **四壳共用同一个程序**，不是四个独立后端。
- `docs/design/TRUSTED_EXECUTION.md`：主机侧可信执行层（Task Contract / Evidence Bundle / Capability Rollout），
  「surface 只是 sealed record 的投影」。
- 扩展通过 EXTENSION_PROTOCOL + agent compositions，不加载 dsh 的 Cordis 插件。
  **v2（reviewed 2026-09-29）**：扩展是**进程外 sidecar**——宿主 spawn 子进程，严格 JSON-RPC 2.0 over NDJSON，
  8 MiB 帧上限，`extension/initialize` 先声明且必须是 manifest 的子集，一个世代最多 4 个 sidecar、共享 30s 启动预算。
  也就是说它选择了「运行期组合 + 进程隔离」，与 dsh 的进程内插件树是两个方向。

### 1.3 opencode —— server + 多客户端

- monorepo：`packages/opencode` 提供 HTTP server（`src/server/server.ts`），
  `packages/desktop`、`packages/web`、`packages/sdk/js` 都是它的客户端。
- 与 trha 的「scheduler + 三壳」形状最接近，区别是它**单一语言栈、单一构建**。

### 1.4 gemini-cli / claurst / clawcode

- gemini-cli：`packages/{core,cli,a2a-server,sdk}`，单进程 CLI + 可选 server。
- claurst：Rust workspace（`src-rust`）。
- clawcode：Python 四层（Agent Runtime / Workflow Engine / Learning Loop / Integration Plane）。
- 三者共同点：**一个进程内的分层**，没有跨语言两跳。

---

## 2. 对照矩阵

| 维度 | **trha** | dsh | Reasonix 2.x | opencode | gemini-cli |
|---|---|---|---|---|---|
| 进程模型 | **3 段 2 跳**：HS 内核(:19433) → TS 编排(:28433) → 壳 | 单 Node 插件树（Desktop 另有 host） | 单 Go 二进制，四壳同程序 | server + 多客户端 | 单 Node CLI（+ 可选 a2a） |
| 语言栈 | Haskell + TS + Electron/React | TS | Go + TS(desktop) | TS | TS |
| 扩展单元 | HS Free-monad 插件（**零引用**）+ TS `ctx` 插件 | Cordis 插件/服务/事件 | 扩展协议 + compositions | 插件 + SDK | MCP + extensions |
| 能力缝 | 5 个 `ctx` 键（events/bridge/pluginManager/tools/sessions） | 十余个（llm/tools/fs/shell/terminals/jobs/sandbox/…） | 13 个 internal 层 | 包边界 | 包边界 |
| 会话真相 | **3 份**（内核/scheduler/CLI） | **1 份**（session log） | state 层 + history | — | checkpoint |
| 工具执行 | 仅 scheduler（宿主） | `ctx.tools` + `tools/*` 事件 | `internal/tools` | server | core tools |
| 内层安全 | **`127.0.0.1` + Bearer + Host/Origin + JSON-only**（2026-10-27 起） | sandbox / approval seam | THS 可信执行 | auth | — |
| 部署 | HS 静态二进制 + Node + Electron | npm 插件树 | 单二进制 | npm | npm |
| 构建门禁 | **~43% Haskell 在构建外** | 全量 CI | 全量 | 全量 | 全量 |
| 差异化 | 本地三值推理（CPU/WebGPU）+ 约束层 | 插件可组合性 | 可信执行 / 四壳一致 | 生态与客户端 | 生态 |

---

## 3. 发现

### A1 会话真相有三份（✅ 已处置，2026-10-27）

> 处置：P-04「两类权威」契约（`docs/contracts/session-truth.md`）+ 内核/scheduler 双侧一致性测试。

| 层 | 存了什么 | 位置 |
|---|---|---|
| 内核 | `SessionSnapshot{agentState, plan, eventCount}` + 事件日志 | `src/core/Core/Session/Types.hs:97-109`，`Storage/JSON.hs:27` |
| scheduler | `PersistedSession{messages, pendingApproval, todos, goal, permissionMode, …}` | `packages/scheduler/src/Server/stateStore.ts:25-51` |
| CLI | `transcript.jsonl`（每行一个事件） | `packages/app/CLI/Core/Transcript.hs:82-88` |

三份都包含**消息序列**，两份包含**审批/计划状态**（内核 `plan`/`agentState`，scheduler `pendingApproval`/`planMode`）。

**对照**：dsh 把这件事写成了规则——「session log 是模型所见上下文的来源，`deriveMessages()` 从它投影」，
而 fork / resume / transcript / telemetry / persistence **全部**从同一份 durable settlement 派生。
trha 没有这条规则，于是三份谁都可以被当成「当前状态」。

**影响**：
- 崩溃恢复的语义取决于读哪一份（内核 checkpoint 与 scheduler JSON 的写入时机不同）。
- 同一 turn 在三处可能得到不同消息序列；排查必须对齐三份。
- 新建壳（Desktop/Web）会再复制一份，除非先定权威。

**限定（对抗性自检后补）**：三层各自持有不同**抽象**本身是合理的（内核是 turn/step 事件源，scheduler 是 UI 视图，
CLI 是本地回放）。问题不在「有三份」，而在**同一语义（消息序列、审批状态）在 ≥2 处可写，且没有一处被声明为权威**。

**建议**（不改判据，先定契约）：
1. 明确「**模型可见 = 已记录**」的唯一日志（候选：内核事件日志，因为它最接近 turn/step 语义）。
2. 其余两处降为**投影/缓存**，并加一条一致性测试：同一 session 从任一份恢复后，`messages` 序列相等。
3. 在 `contracts/protocol-shell-kernel.md` 增加「真相源」一节。

### A2 内层安全弱于外层（✅ 已修复，2026-10-27）

- 外层：scheduler 用 `Authorization: Bearer <TRHA_TOKEN|dev-token>`（`Server/index.ts:75`），契约有记载。
- 内层（**已修复**）：内核现在有三层门 ——
  1. **绑定** `127.0.0.1`（`kernelBindAddress`，此前 `Warp.run` 默认 `*4`）；
  2. **loopback gate**（`src/api/API/Security.hs`）：Host 必须属 loopback（防 DNS rebinding）→
     有 Origin 时必须 loopback（防跨源）→ 改状态的请求必须 `application/json`（防 CSRF 简单请求）→
     `Authorization: Bearer`（常数时间比较）；
  3. **per-launch token**：内核每次启动轮换 32 字节随机 token，原子写入
     `~/.trha/kernel-token`（0600）；scheduler 每次请求前重读文件，并在 401 时重读重试一次
     （`Core/HTTP.ts`、`Bridge/Haskell.ts`、`forwardToKernel`）。这就是「重启握手」——
     内核重启后 scheduler 无需重启。
- `/health` 豁免（供启动探测）。

**回归测试**：`test/SecuritySpec.hs`（12 例：Host/Origin/415/401/大小写/charset/IPv6）、
`test/ServerBindSpec.hs`（绑定地址与端口）。

**修复记录**：文档与注释长期写着「127.0.0.1 by default」，但 `git log -S "setHost"` 在
`src/api/API/Server.hs` 零记录 —— 也就是说**从未实现过**，属于「文档先行、实现缺席」的回归。

**对照**：dsh 的 `ctx.sandbox`/approval seam、Reasonix 的 THS 都是「主机侧执行约束」；
Reasonix 的 `LoopbackGate` 与 trha 现在的实现同构（Host → Origin → Token，拒绝码可区分）。

**剩余**：单内核实例假设 —— token 文件按「一个内核」设计；多实例同端口不共存，
不同端口并行时共享同一文件会互相顶掉（后启动者覆盖）。多实例需改成 `kernel-token-<port>`。

**建议**：内核绑定 `127.0.0.1`（或 UDS）；如确需跨机，加与 scheduler 同源的 Bearer 并在契约中写明。
这是一行改动级别的修复，应优先。

### A3 「微内核 / 一切皆插件」名实不符（✅ 已归档，2026-10-27）

- `architecture/architecture.md` §1：「微内核：核心只管理插件生命周期，功能全部插件化」。
- 实际：`src/core/Core/Plugin/{Free.hs,Types.hs}` **在生产代码里零引用**（全仓无 import），
  只被 `test/PluginSpec.hs` 引用 —— 也就是说它是**测试对象**，不是运行时扩展点。
  **2026-10-27 处置**：两个模块 + `PluginSpec` 已归档到 `archive/haskell-plugin/`；
  `QWEN.md` 的 ownership 表与本段同步改写。
- 真正的扩展机制在 scheduler：`ctx.service('tools'|'events')`、`inject`、`waterfall`、`bail`、`parallel`、`serial`，
  且 `docs/architecture/dsh-capability-seams.md` 记录的就是这一套。

**对照**：dsh 的插件树是**运行时事实**——`dsh --dump-config` 能看到，patch 能替换任何一行。
trha 的 Haskell 插件层在生产路径上没有任何使用面（只有测试在用）。

**影响（修复前）**：新人按 `architecture.md` 找「往哪加功能」会落在未接线的代码上；「微内核」这个卖点只成立在 TS 侧。
**处置**：选择 ② —— 文档改为「扩展点在 scheduler（Cordis 式）」，Haskell 插件层归档。

### A4 内核职责与 2026-09 裁定冲突（✅ 已裁定，2026-10-27）

> 处置：P-06——`plan-reconciliation.md` 改为「内核持有执行状态，但不做业务裁决」。

- 裁定（`plans/plan-reconciliation.md` 文末）：「内核 = **无状态**协议/执行引擎；回合屏障/审批 = 外壳-编排层职责」，
  并据此**关闭 G1**（内核 Plan 状态机）。
- 实现：内核有 `AwaitingApproval` / `Planning` / `ExecutingStep` 与 `transition`（`Core/Session/Manager.hs:107-203`），
  有审批/决策/计划/步骤回报端点（`API/Server.hs:203-213`），有 `stateDir` 持久化。
- 同一份 `plan-reconciliation.md` 的 S1 行又写「**内核闸门已实现**：`AgentState = AwaitingApproval ApprovalRequest` …」，
  而文末写「G1（内核 Plan 状态机）**关闭** …… L1 plan/approval 定位为编排层职责」。
  两段指向同一对象，结论相反。**本文不判哪边对**，只指出记录不一致会让后续决策二选一都错。

**影响**：同一条规则在两段文字里相反；编排层还保留「内核不可达时本地挂起」的降级分支
（`Server/index.ts` 的 `pendingApproval`），于是**审批有两条可能的权威**。

**建议**：以代码为准更新裁定（推荐：承认内核持有审批 FSM，但**只**持久化、不做裁决），
或真正把 FSM 迁到 scheduler；无论哪条，先写一张「审批路径唯一真相」时序图并加测试。

### A5 端口/配置漂移（✅ 已处置，2026-10-27）

> 处置：P-09——`~/.trha/runtime.json` 成为单一发现文件；内核 19433 / scheduler 28433 两端默认一致。

| 项 | 默认值 | 位置 |
|---|---|---|
| scheduler 认为的内核端口 | **19433** | `packages/scheduler/src/Server/index.ts` |
| CLI `serve` 起的内核端口 | **19433** | `packages/app/CLI/Core/Args.hs` |
| 实际部署 | 19433 / 28433（2026-10-27 起，两端默认一致） | 代码默认值 |

配置分三套：CLI `~/.trha/settings.yaml`、scheduler `TRHA_*` 环境变量、内核 `TRHA_*` 环境变量。

**限定（对抗性自检后补）**：走 `packages/scheduler/src/cli.ts` 的正常启动路径会用 `TRHA_LLM_PORT`
覆盖 8080（默认 3333），所以日常运行不一定撞上；风险在**嵌入式调用 `createServer()` 的测试/宿主**
以及按文档默认值配置的读者。severity 因此记「中」而非「高」。
**2026-10-27 更新**：该漂移已修 —— `defaultServerConfig.haskellPort` 与 `cli.ts` 默认都改为 `19433`。

**对照**：dsh 有生成的 config catalog + profile patch 分层；opencode 有 `packages/config`。

**建议**：端口单一来源（scheduler 启动时探测内核，或由 CLI 显式传入并写入契约）；
把 `TRHA_LLM_PORT` 的默认值改成与 CLI 一致，并加一条契约测试断言两边默认相等。

### A6 构建门禁（✅ 已处置，2026-10-27）

> 处置：P-01（按库拆分，44→0）、P-02（sdk 并入 / network 归档）、P-08（`scripts/run-probes.sh` 聚合 exit code）。

`reference/trha-architecture-review.md` §3 已量化：`packages/sdk` 1,059 行（15 文件）、`haskell-network` 1,143 行（17 文件）——
**2026-10-27 已处置**：sdk 拆分后并入根构建，network 与 go 桥归档；
`go-haskell-bridge`（499 行）已于 2026-10-27 归档到 `archive/go-haskell-bridge/`；`Presentation/` 306 行**未接入构建但属规划中的 Presentation 层**（`architecture/presentation-layer.md`，不是死代码）；36 个探针不聚合 exit code。
本文只补一条**架构含义**：这与 A3 同源——「插件化/可扩展」的宣称与**真正进门的代码面**不一致。
建议沿用该文优先级，不在本文重复。

### A7 Web 壳定位不明（✅ 已处置，2026-10-27）

> 处置：P-10——Web 定位为独立客户端，`ci.yml` 增加 web job（typecheck/test/build）。

- `packages/app/Web/src` 17 文件 / 1.6k 行，不在 `cabal.project`、不在 CI。
- 但 scheduler 已经把 `packages/app/Web/dist` 作为 `/studio` 托管（`Server/index.ts:502-622`）；
  `packages/app/Web/dist` 当前**存在**（`assets/` + `index.html`），即静态产物可被托管，但源码构建不进 CI。

**对照**：opencode 的 web 是正式客户端（`packages/web` 参与 monorepo 构建）。

**建议**：明确 Web 是「scheduler 托管的静态 studio」还是「独立客户端」；前者应纳入 CI 构建 `dist`，
后者应补 SDK 与测试。现状是两者都不完整。

### A8 事件列表两份（✅ 已处置，2026-10-27）

> 处置：P-11——`Core/EventRegistry.ts` 单一来源；SSE 路由循环订阅/退订。

- `architecture/event-matrix.md:36` 自己写明：「**SSE 白名单**（`/api/events/:sessionId` 转发 4 事件）与事件注册表
  是两份列表——新增对外事件时二者都要加。」
- 对照 dsh：事件是单一 event map（`docs/event-producer-consumer.md`），新增事件只需登记一次。
- 影响：漏改任一处 ⇒ 事件在本地可见但对 SSE 客户端不可见（或反之），且没有测试会失败。
- 建议：白名单从注册表派生（同一常量），或加一条「注册表 ⊆ 白名单」的契约测试。

---

## 4. 对照出来的优点（不是客套，都是相对参考项目的差异）

| # | 优点 | 对照说明 |
|---|---|---|
| V1 | **内核协议边界最彻底** | 内核暴露 OpenAI / Anthropic / Responses 三 wire，任何语言、任何进程都能替换内核；dsh/Reasonix 是单语言单体，opencode 的 server 仍绑定 JS 生态 |
| V2 | **壳与后端解耦最彻底** | 与 opencode 同构（server + 多客户端），但多一层「编排可换语言」；TUI 完全不需要链接内核代码 |
| V3 | **契约与事件矩阵** | `protocol-shell-kernel.md` + `event-matrix.md` + SSE 白名单，比参考项目的同类文档更细 |
| V4 | **本地推理（CPU/WebGPU）** | 参考项目均无本地推理后端；这是真正的差异化 |
| V5 | **文档诚实度** | 偏差表、未接线清单、探针记录、失败/未验证项都写明；多数项目没有 |
| V6 | **provider 注册表单源** | scheduler 的 `/api/providers*` 全部 `forwardToKernel` 到内核（`Server/index.ts:992-1000`），配置只存 `~/.trha/providers.json`（`API/Providers.hs:45`）——这一点恰好做对了「单一真相」，可作为 A1 的范式 |

**结论**：**不要**为了「像 dsh」而合并进程，也**不要**为了「像 Reasonix」而重写成单二进制。
三层形状是资产；要修的是**真相源、内层边界、宣称与实现的一致性**。

---

## 5. 建议优先级

| 优先级 | 事项 | 规模 | 理由 |
|---|---|---|---|
| **P0** | ~~A2：内核绑 `127.0.0.1` + 认证~~ **已完成（2026-10-27）** | 小 | 绑定 + loopback gate（Bearer/Host/Origin/415）均已实现并有测试 |
| **P0** | A1：声明会话真相源 + 一致性测试 | 中 | 决定后续所有恢复/分叉语义 |
| **P1** | A5：端口/配置单一来源 + 契约测试 | 小-中 | 当前靠环境变量对齐，易漂移 |
| **P1** | A4：审批路径唯一化（更新裁定或迁移 FSM） | 中 | 消除「两处 pendingApproval」 |
| **P1** | A3：插件层接线或归档（**先确认再删**） | 小-中 | 文档与实现对齐 |
| **P2** | ~~A6：构建门禁（sdk/network/bridge 去留）~~ **✅ 2026-10-27 已处置**（sdk 并入、network/bridge 归档）；剩余：探针聚合 | 小 | 见 P-08 |
| **P2** | A7：Web 定位 + CI | 中 | 取决于产品取舍 |

---

## 6. 复核命令

```bash
# A1 三处会话存储
rg -n "snapshot|\.json|writeFile" src/infra/Infrastructure/Storage/*.hs src/core/Core/Session/*.hs | head
sed -n 25,70p packages/scheduler/src/Server/stateStore.ts
rg -n "transcript.jsonl" packages/app/CLI/Core/Transcript.hs

# A2 内层绑定与认证
rg -n "kernelBindAddress|kernelSettings|setHost" src/api/API/Server.hs   # 已绑 127.0.0.1
rg -n "loopback.host_rejected|content-type.not_json" src/api/API/Security.hs
ls -l ~/.trha/kernel-token                                    # -rw------- 64 hex
ss -ltnp | grep 19433                                         # 127.0.0.1:19433

# A3 插件层引用（生产代码应为空；仅测试引用）
rg -ln "Core\.Plugin" --glob '*.hs' --glob '!dist-newstyle' .
# → test/PluginSpec.hs, test/Spec.hs, archive/haskell-plugin/Core/Plugin/{Free,Types}.hs

# A4 内核 FSM
rg -n "AwaitingApproval|Planning|ExecutingStep" src --glob '*.hs'

# A5 端口默认值
rg -n "haskellPort" packages/scheduler/src/Server/index.ts
rg -n "19433" packages/app/CLI/Core/Args.hs

# A7 Web 规模
find packages/app/Web/src -type f | wc -l
```

---

## 7. 本文核实不了的

- **未跑全链路 e2e**（内核 → scheduler → TUI/Desktop）：本文的结论来自静态代码与运行时监听面，不来自端到端行为。
- **未读 `packages/sdk` 的实现**：只采信复核后的行数（1,059 行 / 15 文件）与构建状态。
- **参考项目只读文档与目录结构**：dsh/Reasonix/opencode 的**生产行为**未实测；矩阵中的「对照」是形状对照，不是性能/正确性对照。
- **未验证 Web 壳的运行时行为**：`dist` 存在（`assets/` + `index.html`），但未在浏览器里实测。
- A4 的「裁定 vs 实现」冲突是**文档内部**的冲突，本文只负责指出；哪边为准需要项目所有者裁定。
- **规模与团队差异不在判据内**：trha 是个人项目，dsh/Reasonix 是团队产品；本文只对照**形状**，不比较交付成熟度。
- **行号会漂移**：文档中的 `文件:行号` 是 2026-10-27 工作树的位置；复核请用 §6 的命令，不要依赖行号。

---

## 8. 对抗性自检（本文自己可能的错）

| # | 对自己的质疑 | 结论 |
|---|---|---|
| Q1 | 「会话真相三份」是不是把不同抽象层硬说成冲突？ | 部分成立。已加限定：三层抽象共存合理，冲突点是**同一语义多处可写且无权威声明**（§3 A1「限定」）。 |
| Q2 | 内核真的无认证？会不会有 WAI middleware 在别的模块？ | 已核：`src/api/API/Server.hs` 无 `Authorization` 读取；`sessionGateMiddleware` 是回合门控，不做认证。**绑定已在 2026-10-27 修复为 `127.0.0.1`**（修复前实测 `0.0.0.0:3333`）。 |
| Q3 | 「插件层零引用」是否漏了测试？ | **初稿错了**：`test/PluginSpec.hs`、`test/Spec.hs` 引用了它。已改为「生产代码零引用，仅测试引用」。 |
| Q4 | A5 的 8080 是否真会被用到？ | 复核后确认：正常 `cli.ts` 路径会覆盖默认值，风险在嵌入式 `createServer()` 与文档读者。**2026-10-27 已统一为 19433/28433**，该风险消失。 |
| Q5 | A4 是不是误读「G1 关闭」？ | 复核原文：S1 行说「内核闸门已实现」，文末说「G1 关闭」。两者指向同一 FSM。本文只指出记录矛盾，不判对错。 |
| Q6 | 与既有评审冲突吗？ | 无冲突：`trha-architecture-review.md` 管构建拓扑（S1–S6），本文管架构形状（A1–A8）；A6 直接引用它，不重复。 |
| Q7 | 参考项目结论是否过度推断？ | dsh/Reasonix 只读文档与目录；opencode 只读包布局与 `server.ts`。已在 §7 声明；矩阵标注为「形状对照」。 |
| Q8 | 是否有遗漏的重大架构问题？ | 自检后补了两条：A8（事件双列表）、V6（provider 单一来源）；其余候选项（日志/遥测缺口）已在 `agent-lifecycle-notes.md` 记录，不重复。 |
