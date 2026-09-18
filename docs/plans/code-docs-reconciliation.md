# 代码 ↔ 文档对账（code-docs-reconciliation）

> **日期**：2026-09-13（北京时间）
> **方法**：以**实测命令 + 文件出处**为准，核对「文档宣称」与「代码实际」。每节列出复核命令，可直接重跑。
> **分工**：`docs/plans/plan-reconciliation.md` 对账「计划项 vs 功能实现」；**本文对账「构建 / 接线 / 使用面」**——即"模块是否真的在构建里、是否真的有人用"。
> **触发**：一次按"包"重排 `src/` 的失败尝试（已回退，见 §7），暴露出仓库缺少这一层对账。

---

## 0. 一句话结论

内核（Haskell）的**分层与协议是真实且自洽的**；但有三处「宣称 ✅ / 实际没有」：**WebGPU 未进构建**、**缓存命中率无实现**、**本地推理曾无入口**。另有 4 个包不在根构建里。

> **2026-09-13 更新（两处已闭合）**
> ① `library trha-orchestration`（6 模块 199 行、零 stanza 依赖、零 `import Orchestration.*`、零测试，且 `verifyType` 是恒返 `True` 的假实现）已按所有者裁定**归档出构建** → `archive/orchestration/README.md`；
> ②「本地推理无入口」已由批次 2（D-2）闭合：`"cpu"` 成为一等 provider kind，`adapterFor` / `providerStream` 可达本地引擎（见 `docs/architecture/architecture-intended-vs-actual.md`）。

---

## 1. 实际构建拓扑（实测）

复核命令：
```bash
cat cabal.project
grep -nE "^(library|executable|test-suite)" trha.cabal
grep -n "trha-core\|trha-llm\|trha-api\|trha-infra\|trha-orchestration" trha.cabal
```

```
cabal.project ──▶ packages:  .  +  packages/app/CLI          ← 只有这两个
```

| stanza | 源码根 | 依赖的内部库 | 被谁使用 |
|---|---|---|---|
| `library trha-core` | `src` | — | trha-infra / trha-llm / trha-api / trha-test |
| `library trha-infra` | `src` | trha-core | trha-llm / trha-test |
| `library trha-llm` | `src` | trha-core, trha-infra | trha-api / trha-test |
| `library trha-api` | `src` | trha-core, trha-llm | executable `trha`(CLI) / `trha-kernel-stub` / trha-test |
| `executable trha` (CLI) | `packages/app/CLI` | `trha:trha-api` | — |
| `executable trha-kernel-stub` | `packages/kernel-stub` | `trha-api` | — |
| `test-suite trha-test` | `test` | core, llm, infra, api | — |

★ **`library trha-orchestration` 已于 2026-09-13 移除**（6 模块 199 行、编译通过但零 stanza 依赖、零 `import Orchestration.*`、零测试，且 `verifyType` 为恒返 `True` 的假实现）→ 归档至 `archive/orchestration/`（归档理由与取回步骤见该目录 README）。

**不在根构建（需 `cd` 进去单独构建）**：

| 包 | 规模 | 说明 |
|---|---|---|
| `packages/sdk` | 15 `.hs`（`trha-sdk-core/types/client/utils` + exe + test） | 有独立 cabal，未纳入 cabal.project |
| `packages/haskell-network` | 17 `.hs`（App/Bridge/Core + Main） | 同上 |
| `packages/go-haskell-bridge` | 18 文件（`go/` + `haskell/`） | 同上 |
| `packages/scheduler` | TypeScript | npm 独立构建 |
| `packages/app/Web` | 10 个 ts/tsx | 不在 cabal |

---

## 2. 未接线 / 无人使用（实测）

复核命令：
```bash
grep -rn "WebGPU\|Presentation" --include=*.cabal . | grep -v dist-newstyle   # → 无输出
grep -rn "Infrastructure.WebGPU\|Presentation\." --include=*.hs . | grep -v dist-newstyle
ls archive/orchestration/          # 原 src/Orchestration 6 模块已于 2026-09-13 归档至此
```

| 项 | 规模 | 实测状态 |
|---|---|---|
| ~~`src/Infrastructure/WebGPU/**`~~ | ~~14 文件 / 1344 行~~ | **已失效（2026-09-17 更正）**：旧层（simulation，1344 行）已归档 → `archive/webgpu-legacy/`；**新高层已在构建** —— `library trha-webgpu`（`trha.cabal:222`，`Raw/Types` `Raw/Enums` `Raw/Structs` `Raw/FFI` `Raw/Async` `Context` `Buffer` `Kernel` `Error` 共 9 模块 + `cbits/wgpu_callback_shim.c`），另有 5 个探针可执行（`trha-webgpu-{hello,compute,errorprobe,gf27,gf27matmul}`）与 `trha-webgpu-test`（真机 AMD Navi 44 + Vulkan/radv，3 例）。**仍缺**：未接入**生产推理路径**（`grep -rn "Infrastructure.WebGPU" --include=*.hs src/ \| grep -v "^src/Infrastructure/WebGPU/"` → 无输出）。详见 `plans/webgpu-wiring-plan.md` 与 `architecture/project-overview.md` §5-1 |
| `src/Presentation/**` | 8 文件（Desktop 6 / Web 1 / TUI 1） | **不在任何 cabal**；无外部引用。`docs/architecture/presentation-layer.md` 定义了该层，但从未接线 |
| ~~`library trha-orchestration`~~ | ~~6 模块 / 199 行~~ | **已归档（2026-09-13）** → `archive/orchestration/`。处置理由：零使用者 + `verifyType` 假实现（恒返 `True`）+ 与「编排归外壳、内核不持决策态」裁定冲突。**不是"空库"**：有真实类型骨架，但实现平凡（`parallel = mapConcurrently id`）或为假（`spawnSubAgent` 只写一条 Idle 记录、不启动任何东西） |
| `src/Infrastructure/CPU/Main.hs`、`WebGPU/Main.hs` | 2 文件 | 随层目录存在，未被任何 stanza 声明（不参与编译） |

---

## 3. README 宣称 vs 实测

来源：`README.md` §核心特性 / §技术栈 / §下一步。

| README 宣称 | 实测 | 判定 |
|---|---|---|
| 特性 6 **WebGPU 加速 ✅（Phase 3）** | 代码在，但**不在构建**、simulation、FFI 未接库 | ❌ 未接线 |
| 特性 7 **CPU 优化：多线程 + SIMD + BLAS ✅（Phase 4）** | 三值推理已实现（`docs/plans/pybitnet-ternary-inference-blueprint.md` M1–M20 的测试全绿）；**入口已于 2026-09-13 接通（D-2）**：`"cpu"` 为合法 provider kind，`adapterFor`/`providerStream` 可达 `createCPUAdapter`，引擎按模型路径 memo（`cpuAdapterCache`）；BLAS/SIMD 按 A6 记录仅有"检测 + 标量回退" | 🟡 能力有、性能待办 |
| 特性 4 **99%+ 缓存命中率** | `wc -l src/Core/Cache/*.hs` = **70 行**（Engine 54 + Types 16）；测试 1 例 | ❌ 无对应实现 |
| 特性 5 **完整 SDK ✅（Phase 2）** | `packages/sdk` 存在（4 库 + exe + test），但**不在根构建** | 🟡 存在、未纳入 |
| 特性 3/9 极致并行 / 多 Agent 协作 | TS 侧完成（scheduler 115 用例）；Haskell 侧原 `trha-orchestration` 已归档出构建（2026-09-13） | 🟡 仅 TS 侧 |
| 技术栈 **静态编译（Alpine + musl）** | `Dockerfile.static` 存在，未验证 | 🟡 未验证 |
| 技术栈 **网络库 Haskell Warp + Network** | `packages/haskell-network`（不在根构建） | 🟡 同 |
| 特性 10 桌面应用 | `electron-builder.yml` 配了 `win/nsis`（`extraResources` 带 scheduler-dist + node-runtime），注释提及 mac/linux 的 `NODE_BIN` | 🟡 部分平台 |

---

## 4. 仍然成立的约定（实测通过）

| 约定 | 出处 | 实测 |
|---|---|---|
| 双 cabal 的 CLI `other-modules` 必须同步 | `docs/contracts/protocol-shell-kernel.md` §5.3 | ✅ `diff` 两处 `executable trha` 的 `other-modules` 列表**完全一致** |
| 共享 `src/` 的模块唯一归属 | `docs/plans/desktop-provider-design.md`（注记）→ 已提升到 **`QWEN.md` §Development Conventions** | ✅ 规则现为显式约定，附两个反面案例 |
| 内核/外壳职责分界（内核不持决策态） | `docs/plans/plan-reconciliation.md` §架构原则（2026-09 用户裁定） | ✅ 与 `docs/contracts/protocol-shell-kernel.md` 一致 |

---

## 5. 文档归置（37 份，2026-09-13 已落地）

`docs/` 已按**文档生命周期**分为五个目录，根目录不再有散落文件。完整索引见 `QWEN.md` §Documentation。

| 目录 | 份数 | 内容 |
|---|---|---|
| `docs/architecture/` | 5 | 结构权威：`architecture` · `presentation-layer` · `event-matrix` · `agent-lifecycle-notes` · `dsh-capability-seams` |
| `docs/contracts/` | 3 | 协议契约：`protocol-shell-kernel` · `desktop-port-contract` · `desktop-host-contract` |
| `docs/plans/` | 7 | 活计划：`desktop-provider-design` · `desktop-ui-{execution-plan,port-plan,progress}` · `pybitnet-ternary-inference-blueprint` · `plan-reconciliation` · 本文 |
| `docs/reference/` | 11 | 参考/研究/工具：`source-code-analysis` · `reasonix-{architecture,cli-tui}-analysis` · `cordis-plugin-notes` · `dsh-docs-alignment-plan` · `electron-desktop-plan` · `layer-integration-report` · `github-secrets-setup` · `security-cleanup-guide` · `262974980.jpeg` · `Electron 外壳.txt` |
| `docs/archive/` | 11 | 已完成或已被取代：`implementation-plan-{cli-tui,phase2,shell-sharing}` · `plan-phase2-s2-s3-atomic` · `kernel-tool-execution-plan` · `shell-sharing-design` · `reasonix-shell-sharing-analysis` · `execution-discipline-acceptance` · `implementation-roadmap` · `code-migration-plan` · `pi-integration-plan` |

**分类逻辑**：目录名按"读者该不该照它做"划分 —— `architecture/` 是事实源、`contracts/` 是跨端约定、`plans/` 是进行中、`reference/` 只供参考、`archive/` 已过期（**照它做会出错**，例如 `archive/architecture.md` 的下述 §6、`archive/implementation-roadmap.md` 的目录规划）。

**引用同步**：`README.md`（1 处链接）、`QWEN.md`（规则段 3 处 + Secrets 条 + 重写的 Documentation 索引段）已更新；`docs/` 内部提及见 §8。

---

## 6. 文档层面的结构矛盾（**重要**）

**五份文档曾给出四种不同的目录规划**（这也是那次"按包重排 `src/`"的直接诱因）：

| 文档 | 它描述的结构 | 与现状 |
|---|---|---|
| `QWEN.md` §Architecture Layers / §Module naming | `src/Core/`、`src/LLM/`…**层目录，5 库共享 `src` 为层根** | ✅ **与代码一致** |
| `README.md` §项目结构 | `src/{Core,LLM,API,Infrastructure,Presentation}` | ✅ **已同步（2026-09-13）**：补上 `API/`、去掉已归档的 `Orchestration/` |
| `docs/architecture/architecture.md` §6 | `trha-core/`、`trha-desktop/`、`trha-web/`、`trha-storage/`（**每包独立目录**） | ❌ 现状不是 |
| `docs/archive/implementation-roadmap.md` §1.2 | `pi-trha/{core-engine,orchestration,presentation,shared}` | ❌ 从未采用 |
| `docs/archive/code-migration-plan.md` | `src/core-engine/`、`src/orchestration/*.ts` | ❌ 从未采用 |

**结论**：只有 `QWEN.md` / `README.md` 的"层目录"描述与代码一致；其余三份是不同阶段的构想残留。**这是坑的来源** —— 按 `architecture.md` §6 去"根治"目录结构，会直接撞上 `QWEN.md` 的既有约定。

**其他文档缺陷**：
- `docs/reference/layer-integration-report.md` 第 3 行是未渲染的模板变量 `**日期**: $(date)`；其「前端层/后端层：接口定义完整，待实现」容易被误读为已完成。
- 37 份文档交叉引用最多 3 次（重组前；`QWEN.md` 当时只索引 6 份）→ 新会话极易读到过期文档。现已由 §5 的目录分离 + `QWEN.md` 完整索引缓解。
- `docs/archive/implementation-roadmap.md` 的「缓存命中率 > 99%」等指标是**目标**而非实测。

---

## 7. 待办（均未实施）

| # | 事项 | 类型 | 风险 |
|---|---|---|---|
| ~~1~~ | ~~共享 `src` 归属规则提升到 `QWEN.md`~~ | 文档 | **已完成（2026-09-13）** |
| ~~3~~ | ~~新建本对账文档~~ | 文档 | **已完成（2026-09-13）** |
| ~~9~~ | ~~`docs/` 按分类建立五个目录并归置 37 份 + 同步引用~~ | 文档 | **已完成（2026-09-13）** |
| ~~2~~ | ~~修正 `docs/architecture/architecture.md` §6，使其与现状（层根结构）一致，或明确标注"规划 vs 现状"~~ | 文档 | **已完成（2026-09-13）**：§6 标题与正文明确标注「⚠️ 规划，不是现状」，给出层根结构实情并指向 `QWEN.md` 为结构权威，附 68-rename 回退实例 |
| ~~4~~ | ~~给 `README.md` 的 Phase 表加实测注记（WebGPU 未接线 / 缓存 70 行 / SDK 不在构建）~~ | 文档 | **已完成（2026-09-13）**：Phase 表改为「进度 + 实测状态」两列，逐项标注（WebGPU ❌未接线 / 缓存实为 70 行 / SDK 不在根构建 / CPU 🟡入口已通但 BLAS·SIMD 仅标量回退 / Phase 6 仅 TS 侧 / Phase 7 仅 linux 已验） |
| ~~5~~ | ~~处置 `library trha-orchestration`（死库）：接入、或移出构建~~ | 代码 | **已完成（2026-09-13）**：所有者裁定「归档出构建」→ `archive/orchestration/` |
| ~~6~~ | ~~丢弃 `stash@{0}`（一次已回退的按包重排 `src/` 尝试）~~ | 仓库卫生 | **已完成（2026-09-13）**：`git stash list` 输出为空 —— 该 stash 早已清理，无可丢条目 |
| ~~7~~ | ~~决定本地推理后端如何接入内核（provider `kind` / 启动参数）~~ | 架构 | **已完成（2026-09-13）**：裁定方案 A —— 本地推理即 provider `kind="cpu"`（`peBaseUrl` 承载模型路径） |
| ~~8a~~ | ~~Presentation 层：接线或显式标注为未接线~~ | 文档 | **已完成（2026-09-13）**：所有者裁定「显式标注」→ `presentation-layer.md` 头部加未接线标注（含纠正其 6 个实际不存在的文件清单） |
| 8b | **WebGPU 接线**（所有者裁定为「C. 真正接线」） | 代码 | **进行中（多批次工程）**：数据流程图 + W1–W7 原子分解见 `docs/plans/webgpu-wiring-plan.md`；**W1 已完成**（库就位 + `nm` 证伪旧 FFI 的编造符号）；W2–W7 待做 |

---

## 8. 变更记录

| 日期 | 变更 |
|---|---|
| 2026-09-13 | 初版：构建拓扑 / 未接线清单 / README 宣称核对 / 文档分类建议（A–E）/ 结构矛盾 |
| 2026-09-13 | `docs/` 归置落地：建 `architecture/` `contracts/` `plans/` `reference/` `archive/` 五目录并移动全部 37 份；同步更新 `README.md` 链接与 `QWEN.md`（规则段路径、Secrets 条、重写的 §Documentation 索引）；本文档自身移入 `plans/` 并更新全部路径引用 |
| 2026-09-13 | **D-2 闭合**（`commit 9a6dd6f`）：「本地推理无入口」已修 —— `"cpu"` 成一等 provider kind，`adapterFor` / `providerStream` 可达 `createCPUAdapter`，引擎按模型路径 memo（`cpuAdapterCache`）；整套 177/0/4、CLI 182/0、`build all` EXIT=0。同步更新本文 §0 / §3（特性 7）/ §7 #7 与 `architecture-intended-vs-actual.md`（§0 现状行、§3 现状图、§4 D-2、§5 状态分档、§6 批次表） |
| 2026-09-13 | **`library trha-orchestration` 归档出构建**（所有者裁定「A. 归档出构建」）：6 模块 199 行、编译通过但零 stanza 依赖 / 零 `import Orchestration.*` / 零测试，且 `verifyType` 为恒返 `True` 的假实现 → `archive/orchestration/`（含 README：实测事实 / 逐块评估 / 架构理由 / 取回步骤）；同时从 `trha.cabal` 删除该 stanza。同步更新本文 §0 / §1 拓扑 / §2 清单 / §3（特性 3·9）/ §6，以及 `README.md` §项目结构、`docs/README.md` 索引 |

| 2026-09-17 | **§2 的 WebGPU 行更正**：原写「不在任何 cabal」已失效 —— 新高层已进构建（`library trha-webgpu`，`trha.cabal:222`，9 模块）+ 5 探针 + `trha-webgpu-test` 真机 3 例；仍缺的是**未接生产推理路径**（`grep … src/ \| grep -v WebGPU/` → 无输出）。判定依据与漂移清单见 `docs/architecture/project-overview.md` §5-1。同批更正：`QWEN.md`（层表去掉已归档的 `src/Orchestration/`、5 库组成改为 core/llm/api/infra/webgpu、模块归属表加 `Infrastructure.WebGPU.*`）、`.github/workflows/ci.yml`（GHC 9.4.8 → 9.14.1） |

---

## 附：本次核对用到的命令（可复跑）

```bash
cat cabal.project
grep -nE "^(library|executable|test-suite)" trha.cabal
grep -n "trha-orchestration" trha.cabal                    # → 无输出（2026-09-13 已移除）
ls archive/orchestration/                                   # → 归档位置（6 模块 + README）
grep -rn "^import.*Orchestration\." --include=*.hs src test packages   # → 无输出
grep -rn "WebGPU\|Presentation" --include=*.cabal . | grep -v dist-newstyle
grep -rn "Infrastructure.WebGPU\|Presentation\." --include=*.hs . | grep -v dist-newstyle
wc -l src/Core/Cache/*.hs
sed -n '45,52p' src/Infrastructure/WebGPU/Buffer.hs
head -14 src/Infrastructure/WebGPU/README.md
# 原生推理接入（D-2，已闭合）
grep -n '"cpu"' src/Core/Provider/Types.hs
grep -n "cpuAdapterFor\|cpuAdapterCache" src/API/ProviderRuntime.hs
diff <(sed -n '/^executable trha$/,/ghc-options/p' trha.cabal | grep "^    ") \
     <(sed -n '/^executable trha$/,/ghc-options/p' packages/app/CLI/trha-cli.cabal | grep "^    ")
# docs 归置后的引用体检（应只命中新路径）
grep -rn "docs/[a-z-]*\.md" --include=*.md . | grep -v dist-newstyle | grep -v node_modules
```
