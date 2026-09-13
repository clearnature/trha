# docs/ 导览

> 本目录共 **38 份文档**，按**文档生命周期**分为五个子目录（2026-09-13 归置；动因与分类依据见 `plans/code-docs-reconciliation.md` §5–§6）。
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
2. **`architecture/architecture-intended-vs-actual.md`** —— **先读这份**：项目**意图**（推理内核）vs 现状、偏差 D-1…D-9、状态分档
3. `architecture/architecture.md` —— 分层与数据流（注意其 §6 包结构规划与现状不符）
4. `contracts/protocol-shell-kernel.md` —— 跨端协议总账（端点 / SSE 帧 / 凭证）
5. `plans/plan-reconciliation.md` —— 计划 vs 现实（含**内核/外壳职责分界**的架构原则）
6. `plans/code-docs-reconciliation.md` —— 代码 vs 文档（构建 / 接线 / 使用面 + 未接线清单）
7. 之后按任务进入 `plans/` 的对应文档

## 索引

### `architecture/` — 结构权威与项目意图（6）

- **`architecture-intended-vs-actual.md`** — **意图 vs 现状**：规范基座链（Agda「律算合一」→ pyBitNet《架构宪法》→ 本仓 CPU 实现）· 意图架构图 · 现状架构图（带 ✅/⚠️/❌）· 偏差 D-1…D-9 · 状态分档 A–E · 待澄清项。**项目愿景此前未写入任何文档，导致过一次严重误读，故新会话应先读本文**
- `architecture.md` — 分层、核心模块、数据流、技术选型。⚠️ §6「包结构规划」写的是"每包独立目录"，与现状不符（见 `plans/code-docs-reconciliation.md` §6）
- `presentation-layer.md` — Presentation 层（Desktop / Web / TUI）设计；**该层代码尚未接入构建**
- `event-matrix.md` — 每个事件的 producer / consumer / SSE 转发 / 持久化位置
- `agent-lifecycle-notes.md` — 一次 step → 多个模型轮次 → 工具执行的可观测面（含遥测缺口标注）
- `dsh-capability-seams.md` — 能力缝（`ctx.<key>` 服务）与「加 X → 机制」速查表

### `contracts/` — 跨端契约（3）

- `protocol-shell-kernel.md` — 外壳（CLI/TUI/桌面/Web）↔ 编排层（`packages/scheduler`，默认 :3456，Bearer token）↔ 内核 的端点、SSE 帧、凭证总账（Phase 3 三端基线）
- `desktop-port-contract.md` — UI ↔ 后端 `Port` 契约（组件只经 `port/` 访问后端，禁止直接 `fetch`）
- `desktop-host-contract.md` — Desktop ↔ Scheduler 宿主契约 v1（握手 / 租约 / 日志 stderr / 安全基线）

### `plans/` — 进行中（7）

- `desktop-provider-design.md` — Provider 三层体系（内核 registry + scheduler 透传 + Desktop UI）；P1–P8 / A1–A5 完成。**「共享 `src/` 模块唯一归属」规则的原始出处就在这里**（第 60/63 行的结构注意）
- `desktop-ui-execution-plan.md` — Desktop UI 移植的原子表与预算（T1–T12；`T5b` resume、`T12a` 清理未完成）
- `desktop-ui-port-plan.md` — Desktop UI 分析与能力矩阵（执行计划的前置）
- `desktop-ui-progress.md` — Desktop/Electron 跨会话 checkpoint（已完成基线 + 待办索引）
- `pybitnet-ternary-inference-blueprint.md` — CPU 三值推理内核蓝图（M1–M20，逐条标注参考实现行号）
- `plan-reconciliation.md` — 计划 vs 现实（**功能面**）；文末「架构原则」是内核/外壳职责分界的用户裁定
- `code-docs-reconciliation.md` — 代码 vs 文档（**构建 / 接线 / 使用面**）；未接线清单（WebGPU / Presentation）与待办（原 `trha-orchestration` 199 行已于 2026-09-13 归档出构建 → `../../archive/orchestration/`）

### `reference/` — 参考、研究、运维（11）

- `source-code-analysis.md` — 四个来源项目（DeepSeek-Harness / Pi / Reasonix / trha）的结构与融合映射
- `reasonix-architecture-analysis.md` — Reasonix Studio v2.11.0 架构剖析（内核-外壳分离、通信、发布线、安全模型）
- `reasonix-cli-tui-architecture-analysis.md` — Reasonix CLI/TUI → trha 移植基线（能力矩阵 F1–F10）
- `cordis-plugin-notes.md` — settings 命令与 Cordis 插件架构对照笔记
- `dsh-docs-alignment-plan.md` — deepseek-harness 十份概念文档的对齐计划与落地状态
- `electron-desktop-plan.md` — Electron 壳对齐（E2 原子）+ 打包线（P1–P5 linux）
- `layer-integration-report.md` — Phase 1 分层集成报告。⚠️ 第 3 行含未渲染的模板变量 `$(date)`
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
