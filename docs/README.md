# docs/ 导览

> 本目录共 **57 份文档**（2026-10-30 追加；计数规则 = `reference/` 下按**条目**计，其余按 `.md` 文件计），按**文档生命周期**分为五个子目录（2026-09-13 归置；动因与分类依据见 `plans/code-docs-reconciliation.md` §5–§6）。
>
> **结构权威**是 `../QWEN.md`（§Architecture Layers / §Development Conventions / §Documentation）与 `architecture/architecture.md`。本文件只是**浏览用导览**，如有冲突，一律以 `QWEN.md` 为准。

## 怎么用这五个目录

| 目录 | 什么时候看 | 什么时候**不要**照它做 |
|---|---|---|
| `architecture/` | 要理解分层、事件、生命周期、能力缝，以及**项目的意图** | —（它是结构事实源） |
| `contracts/` | 要改外壳 ↔ 编排 ↔ 内核的接口、事件帧、凭证 | —（跨端约定，改动必须同步契约测试） |
| `plans/` | 要接续进行中的工作、查缺口与对账 | 未勾选的计划项别当成"已实现" |
| `reference/` | 要查参考实现分析、CI/密钥运维、工具笔记 | 它是分析与笔记，不是规范 |
| `archive/` | 要追溯历史决策与当时的计划 | **照它做会出错** —— 已完成或被取代，且含与现状分叉的结构描述 |

## 推荐阅读顺序（新会话 / 新人）

1. `../QWEN.md` —— 开发约定、层表、完整文档索引
2. **`architecture/project-overview.md`** —— **要全貌先读这份**：技术栈 / 构建拓扑 / 现状架构图 / **逐计划完成度** / 未完成·未验证清单 / 文档漂移清单 / 复核命令
2b. **`architecture/architecture-snapshot-2026-10-27.md`** —— **要「现在长什么样」读这份**：实测分层图、每层模块细分、一次 turn 的数据流、问题索引（S1–S3 / C1–C3 / D1–D4）
3. **`architecture/architecture-intended-vs-actual.md`** —— **要理解意图读这份**：项目**意图**（推理内核）vs 现状、偏差 D-1…D-9、状态分档
4. `architecture/architecture.md` —— 分层与数据流（注意其 §6 包结构规划与现状不符）
5. `contracts/protocol-shell-kernel.md` —— 跨端协议总账（端点 / SSE 帧 / 凭证）
6. `plans/plan-reconciliation.md` —— 计划 vs 现实（含**内核/外壳职责分界**的架构原则）
7. `plans/code-docs-reconciliation.md` —— 代码 vs 文档（构建 / 接线 / 使用面 + 未接线清单）
8. 之后按任务进入 `plans/` 的对应文档

## 索引

### `architecture/` — 结构权威与项目意图（8）

- **`project-overview.md`** — **技术栈 · 架构 · 计划完成度** 的一页综合视图：分层技术表、构建拓扑（cabal stanza）、依赖清单、`3rdparty/`、现状架构图、职责分界、跨端协议、逐计划完成度总账、未完成/未验证清单、**文档漂移清单**、复核命令与机器回执 id。想**快速建立全貌**或查「某项到底做完没有」从这份进（它是视图，不是权威 —— 冲突时以本文其余各份为准）

- **`architecture-intended-vs-actual.md`** — **意图 vs 现状**：规范基座链（Agda「律算合一」→ pyBitNet《架构宪法》→ 本仓 CPU 实现）· 意图架构图 · 现状架构图（带 ✅/⚠️/❌）· 偏差 D-1…D-9 · 状态分档 A–E · 待澄清项。**项目愿景此前未写入任何文档，导致过一次严重误读，故新会话应先读本文**
- `architecture.md` — 分层、核心模块、数据流、技术选型。⚠️ §6「包结构规划」写的是"每包独立目录"，与现状不符（见 `plans/code-docs-reconciliation.md` §6）
- **`architecture-snapshot-2026-10-27.md`** — **当前架构快照（实测）**：一页分层图（L0 规范基座 → L1 内核 → L2 编排 → L3 壳 → Provider）、各层模块细分、一次 turn 的数据流、关键契约、**问题索引**（S1–S3 结构性 / C1–C3 一致性 / D1–D4 债务）与「不是问题的取舍」。要「现在长什么样」先看这份；问题编号与 `reference/trha-architecture-benchmark-review.md` 的 A1–A8 互为索引
- `presentation-layer.md` — Presentation 层（Desktop / Web / TUI）设计；**该层代码尚未接入构建**
- `event-matrix.md` — 每个事件的 producer / consumer / SSE 转发 / 持久化位置
- `agent-lifecycle-notes.md` — 一次 step → 多个模型轮次 → 工具执行的可观测面（含遥测缺口标注）
- `dsh-capability-seams.md` — 能力缝（`ctx.<key>` 服务）与「加 X → 机制」速查表

### `contracts/` — 跨端契约（4）

- **`session-truth.md`** — **会话真相契约（2026-10-27）**：两类权威——A 类「模型可见历史」以内核事件日志为准，B 类「UI 元数据」（title/tags/todos/goal/permissionMode）以 scheduler `stateStore` 为准；CLI `transcript.jsonl` 只读回放。含恢复规则、一致性要求与三阶段迁移

- `protocol-shell-kernel.md` — 外壳（CLI/TUI/桌面/Web）↔ 编排层（`packages/scheduler`，默认 :28433，Bearer token）↔ 内核 的端点、SSE 帧、凭证总账（Phase 3 三端基线）
- `desktop-port-contract.md` — UI ↔ 后端 `Port` 契约（组件只经 `port/` 访问后端，禁止直接 `fetch`）
- `desktop-host-contract.md` — Desktop ↔ Scheduler 宿主契约 v1（握手 / 租约 / 日志 stderr / 安全基线）

### `plans/` — 进行中（16）

- **`compact-weights-plan.md`** — **紧凑权重（2026-10-27，P-12 已完成）**：默认走 `SovereignIntWeightsC` + `sovereignForwardFullCompact`；`trha-cpu-braintoken` 实测 **2.5s/token、RSS 8.6GB**（旧流式 222s/40GB 仅作对照）；C1–C5 已落地，门禁 ≤5s / ≤12GB

- **`sandbox-decisions.md`** — **沙箱决策记录（ADR-001–007，2026-10-29 冻结）**：C4 `scopeId = sessionId`（证据：`parentSessionId`/`createSession`）、工具执行归属（编排层强制 + 内核策略快照校验）、实验对比留 host、默认策略（交互 `WorkspaceWrite` / 子代理 `ReadOnly`）、工具链静态表 + 探针、`Remote` 仅预留、Windows 放 P4。每条含背景/备选/代价/判据/复审触发；变更需新增 ADR 并注明 supersede

- **`sandbox-delivery-plan.md`** — **沙箱交付计划（2026-10-29，未开工）**：范围与前提、M0–M5 里程碑（接口冻结 → Linux → 多智能体 → macOS → Windows → Unix/边缘）、**WBS 48 项原子任务**（含 **T0.13 接线契约**、**T2.7/T2.8 消融实验批**）、关键路径、1 周迭代、7 条 DoD 门禁、接口冻结后的 RFC 变更控制、风险与 30% 缓冲、6 项度量、交付物清单、**§11 技能与智能体协作**（阶段技能映射、单人效率 7 条规则、PERT 估算、攻击面清单）。总计 **55–60 人日 + 30% 缓冲 ≈ 72–78 人日（约 15 周）**

- **`sandbox-handoff.md`** — **沙箱交付交接快照（2026-10-30）**：M0–M5 逐项实况、剩余工作按阻塞原因分类（需真机 / 证书 / 虚拟化）、会话开工与收尾约定、已知坑（systemd-run 的 D-Bus 降级、guest 内 `sandbox status` 的判定）。新会话接手沙箱工作先读这份

- **`remote-access-bot-plan.md`** — **远程访问与 IM Bot 接入规划（2026-10-30，未实现）**：DSH / reasonix / trha 三家做法对比（web 暴露 → `SAFETY.md` 免责；bot + webhook 仍需 8080 公网入站）、方案 A–D 推演（选定 **IM 长连接**：零入站端口）、移植清单 B1–B8（allowlist / pairing / ask 姿态 / 队列语义 / 各平台 adapter）、已就位的前置修复与还缺的三项、验收判据（`ss -ltn` 只有 loopback 等）

- **`sandbox-architecture.md`** — **沙箱架构第一版设计基线（2026-10-29，未实现）**：现状证据（无 OS 级沙箱、`permissionRules` 默认 allow 且注释误称「沙箱已兜底」）、L1–L4 分层、**§3.1 平台能力矩阵**、**§4.2.1 gVisor 采用与 bwrap personality**、**§4.3 成熟工具访问区对照**、**§4.4 真实事件复盘（Anthropic 2026-05）**、**§5.3.1 实验批（消融）模型**（基线只读/变体隔离/复现元数据/批次配额）、**§5.5.1–5.5.3 内核接线契约与工具执行归属**、**§5.8 实现语言与组件边界**、Windows 权限与路径专项、强类型 `Policy`/`Scope`/`narrow` 设计、多智能体 Scope 模型、runner NDJSON v1 协议、平台后端、编译期+黄金+探针+多 agent+**消融实验判据（§6.5）**、P0–P5 计划与风险。**§5.7 接口一次性冻结**：Haskell 公开 API、协议全部帧、TS `sandboxedSpawn`/`runExperiment`/HTTP 端点、`~/.trha/sandbox.yaml` schema（含 read/write/protectedSubpaths/tmp/experiments）、CLI 命令、P0 落地文件清单。**§9 参考代码索引**：R1–R11 + D1–D4，正文逐条标注可追溯、L1–L4 分层、**§3.1 平台能力矩阵**、**§4.2.1 gVisor 采用与 bwrap personality**、**§4.3 成熟工具访问区对照**、**§4.4 真实事件复盘（Anthropic 2026-05）**、**§5.3.1 实验批（消融）模型**（基线只读/变体隔离/复现元数据/批次配额）、**§5.5.1–5.5.3 内核接线契约与工具执行归属**、**§5.8 实现语言与组件边界**、Windows 权限与路径专项、强类型 `Policy`/`Scope`/`narrow` 设计、多智能体 Scope 模型、runner NDJSON v1 协议、平台后端、编译期+黄金+探针+多 agent+**消融实验判据（§6.5）**、P0–P5 计划与风险。**§5.7 接口一次性冻结**：Haskell 公开 API、协议全部帧、TS `sandboxedSpawn`/`runExperiment`/HTTP 端点、`~/.trha/sandbox.yaml` schema（含 read/write/protectedSubpaths/tmp/experiments）、CLI 命令、P0 落地文件清单。**§9 参考代码索引**：R1–R11 + D1–D4，正文逐条标注可追溯

- **`improvement-plan-2026-10-27.md`** — **改进计划（2026-10-27）**：合并 qwen 2026-09-20 的独立评价（S1–S6）与本次对照评审（A1–A8），并**重新核实**现状（44 个重复模块、sdk 已并入根构建、haskell-network 已归档（2026-10-27 处置；旧记录 92 文件/11,781 行误把 dist-newstyle 计入）、Presentation 8 文件、26 executable）。含 P0/P1/P2 路线、两项需用户裁定（重复模块归属、死代码去留）、与「不建议做」清单

- `desktop-provider-design.md` — Provider 三层体系（内核 registry + scheduler 透传 + Desktop UI）；P1–P8 / A1–A5 完成；A6（自研 CPU 推理）M1–M2 完成、M3–M6 未做。**「共享 `src/` 模块唯一归属」规则的原始出处就在这里**（第 60/63 行的结构注意）
- `desktop-ui-execution-plan.md` — Desktop UI 移植的原子表与预算（T1–T12；`T5b` resume、`T12a` 清理未完成）
- `desktop-ui-port-plan.md` — Desktop UI 分析与能力矩阵（执行计划的前置）
- `desktop-ui-progress.md` — Desktop/Electron 跨会话 checkpoint（已完成基线 + 待办索引）
- `pybitnet-ternary-inference-blueprint.md` — CPU 三值推理内核蓝图（M1–M20，逐条标注参考实现行号）
- `plan-reconciliation.md` — 计划 vs 现实（**功能面**）；文末「架构原则」是内核/外壳职责分界的用户裁定
- `code-docs-reconciliation.md` — 代码 vs 文档（**构建 / 接线 / 使用面**）；未接线清单（WebGPU / Presentation）与待办（原 `trha-orchestration` 199 行已于 2026-09-13 归档出构建 → `../../archive/orchestration/`）
- `electron-44-upgrade.md` — **Electron 28 → 44 升级的变更与待办**：已完成部分（依赖 + 二进制已验证）、待处理（`chrome-sandbox` SUID 权限、实机启动验证、electron 二进制镜像配置、改动未提交）
- `verification-criteria.md` — **判据是什么**：C1–C5（代数结构 / 类型不变量 / 多实现全等 / 因果语义 / 约束↔外部推理）+ 覆盖进度表；**性能不是判据**
- `file-completion-tracking.md` — 逐**文件**的完成状态 + 验证方式 + 证据（按计划项核对见 `plan-reconciliation.md`）
- `webgpu-wiring-plan.md` — WebGPU 后端接线：数据流程、W1–W7 / T1–T4 原子分解（均已跑通）、12 条「照文档写会踩」的坑；**未接生产推理路径**

### `reference/` — 参考、研究、运维（16）

- `source-code-analysis.md` — 四个来源项目（DeepSeek-Harness / Pi / Reasonix / trha）的结构与融合映射。⚠️ 2026-10-27 起标注为**早期分析**，现状以 `architecture/architecture-snapshot-2026-10-27.md` 为准
- `microkernel-lineage.md` — **微内核谱系**（2026-10-27）：概念来自 deepseek-harness/Cordis（进程内插件树、可逆副作用），Haskell 手法来自 Yi 的 `dynamic-state`（`HashMap ConcreteTypeRep Dynamic` 类型索引状态），进程外模型参考 Reasonix Extension Protocol v2（sidecar + NDJSON JSON-RPC + manifest）。**§3.5 另收 Haskell 侧完整 harness 参考**：`/data/work/functional-programming/hs` 的 haskell-agent（30+ 包、runtime daemon、agent-server）、langchain-hs（RunnableTree / StateGraph）、tricorder（daemon + TUI + MCP 插件）。含四者对照表与 trha 的实际落点（`Core.Plugin` 生产零引用、真正扩展面在 scheduler）
- `reasonix-architecture-analysis.md` — Reasonix Studio v2.11.0 架构剖析（内核-外壳分离、通信、发布线、安全模型）
- `reasonix-cli-tui-architecture-analysis.md` — Reasonix CLI/TUI → trha 移植基线（能力矩阵 F1–F10）
- `cordis-plugin-notes.md` — settings 命令与 Cordis 插件架构对照笔记
- `dsh-docs-alignment-plan.md` — deepseek-harness 十份概念文档的对齐计划与落地状态
- `electron-desktop-plan.md` — Electron 壳对齐（E2 原子）+ 打包线（P1–P5 linux）
- `layer-integration-report.md` — Phase 1 分层集成报告。⚠️ 第 3 行含未渲染的模板变量 `$(date)`
- `trha-architecture-review.md` — **外部独立复核**（2026-09-21）：构建拓扑实测（41 处同名不同类型、~13.6k 行构建外代码、Go 桥无人引用、Presentation 未接线、36 探针缺聚合）、逐项技术栈评价、建议优先级。⚠️ 判据是**工程可维护性**，与项目 C1–C5（数学正确性）不同，勿混用；文中「死代码」一词按项目规划应读作「未接线」
- `trha-architecture-benchmark-review.md` — **架构形状对照审核**（2026-10-27）：对照 DeepSeek-Harness（Cordis 插件树 / capability seams）、Reasonix 2.x（单二进制四壳 / 可信执行）、opencode（server + 多客户端）。发现 A1 会话真相三份、A2 内核 0.0.0.0 无认证、A3 插件层名实不符、A4 内核职责与裁定冲突、A5 端口/配置漂移。⚠️ 判据是**架构一致性与可演进性**，不与 C1–C5、也与上一份的构建可维护性混用
- `cangjie-replacement-feasibility.md` — **"用仓颉替代 Haskell"可行性**（2026-09-21）：仓颉生态与类型系统实测、内核实际依赖 GHC 的面（`class` 仅 2 处、`type family` 0 处、GADT 语法命中全是注释里的 Agda）、最小可行实验路径。含对两处初判错误的更正
- `cangjie-typing-probes/` — 上文的**可复现探针**（9 个 `.cj` + `run.sh`，`bash run.sh` → 9/9 断言）
- `github-secrets-setup.md` — CI 密钥配置
- `security-cleanup-guide.md` — Git 历史敏感信息清理
- `262974980.jpeg`、`Electron 外壳.txt` — 素材（后者：Reasonix v2.11.0 pre-release 说明，Wails→Electron 迁移背景）

### `archive/` — 已归档：已完成或已被取代（11）

- `implementation-plan-cli-tui.md`（P1.1–P1.6 ✅）、`implementation-plan-phase2.md`、`plan-phase2-s2-s3-atomic.md`
- `kernel-tool-execution-plan.md`（方案 A 的 K1–K6 全部 ✅）
- `implementation-plan-shell-sharing.md`、`shell-sharing-design.md`、`reasonix-shell-sharing-analysis.md`（共享外壳设计，已由编排层接管）
- `execution-discipline-acceptance.md`（Phase 2 执行纪律，范围已过）
- `implementation-roadmap.md`（`pi-trha/` 十二周计划，**从未采用**）、`code-migration-plan.md`（目标目录 `src/core-engine/`，**从未采用**）、`pi-integration-plan.md`

## 维护约定

1. **归档而非删除** —— 完成或被取代的文档移入 `archive/`，内容不改（历史即证据）。
2. **新增文档落位** —— 结构类/意图类 → `architecture/`；跨端接口 → `contracts/`；进行中 → `plans/`；分析/运维/素材 → `reference/`；已完成 → `archive/`。
3. **结构变更要同步两处** —— `../QWEN.md` §Documentation 的索引 + 本文件。
4. **移动文档必须同步引用** ——
   ```bash
   grep -rn "docs/[a-z-]*\.md" --include=*.md --include=*.hs --include=*.cabal . \
     | grep -v dist-newstyle | grep -v node_modules
   ```
   注意区分**外部项目**的同名文档（如 `deepseek-harness docs/agent-lifecycle.md`）与 `packages/sdk` 自有的 `docs/sdk-api.md` 相对路径 —— 这些**不要改**。
5. **不要在 `docs/` 根目录新增文档** —— 根目录只保留本导览。
6. **涉及"项目意图"的改动，先更新 `architecture/architecture-intended-vs-actual.md`** —— 它是意图的单一入口；改意图必须同步它，避免再次出现"愿景只在对话里、不在文档里"。
