# 架构：意图 vs 现状（architecture — intended vs actual）

> **日期**：2026-09-13（北京时间）
> **为什么有这份文档**：项目愿景 —— 以 Haskell 强类型论 + Agda 等证明器支撑的**推理内核**（CPU/WebGPU 原生推理，并对外部 API 推理施加类型论/因果约束）—— **此前没有写进任何文档**：`README.md` 只写 "microkernel agent harness"。
> 后果是实测过的：一次 AI 协作会话（2026-09-13）读遍 `docs/` 全部 37 份后，仍把它误读成"agent harness 复刻"，并据此差点做出错误的目录重构（已回退）。
> 本文把**意图**与**现状**并置，供后续协作者（人/AI）校正认知。

---

## 0. 一句话

| | 内容 |
|---|---|
| **意图** | 内核是**带类型论与因果约束的推理中枢**。外部模型（API）与本地三值模型都只是它的**推理基座**；内核对推理过程做**感知与约束**。 |
| **现状** | 推理基座（本地三值，M1–M20 全绿）与约束原语（T⁶ 验证 / 6×6 因果图 / 五行四步链）**都已实现**，但：① 本地推理**在内核启动路径上不可达**；② 约束原语与**外部 API 推理通道完全不相交**。 |
| **工程手段** | TS 全功能编排（对现有技术的利用）与 Electron（跨平台渲染）是**手段**，不是核心。 |

---

## 1. 规范基座（外部仓库，权威链）

本仓不是从零发明数学；它**照外部规范实现并逐条对拍**：

| 层 | 位置 | 内容 | 证据 |
|---|---|---|---|
| 规范（形式化） | `/data/work/discrete-mathematics` | **律算合一**（Agda）：`L0 模2硬件 → L1 GF(3) → L2 Z/3¹¹Z → 桥LCM → L3 手征离合 → L4 T⁶环面(144×46=6624) → L5 纳音孤子 → L6 仲吕倍频 → L7 陈数守卫(C=±2) → L8 全息观测(46 驻波)` | 该仓 `README.md`；含 `Makefile`/`_build`/`Generated` |
| 参考实现 + 宪法 | `/data/trit/pyBitNet` | 三值/声子模型参考实现；**《架构宪法 v1.1》**：刚性常量不可变、**数学结构不可简化**（"LLM 的简化本能在此项目中是破坏性的"）、Christoffel 平行移动替代注意力 | 该仓 `ARCHITECTURE_CONSTITUTION.md` |
| Haskell 实现 | 本仓 `src/Infrastructure/CPU/**` | GGUF/SOV3 容器、8 种反量化、S² 几何、GF(3) 算子、Christoffel 运输、60 层前向、五行层 | `docs/plans/pybitnet-ternary-inference-blueprint.md`（759 行，逐条标参考行号） |

**对拍方式**：`test/Spec.hs` 中大量以"权威 `GF9.agda` / `GF27.agda` / `GF81.agda` / `LCM.agda` / `IhC60Vibration.agda` / `Zhonglv.lengToNat`"为注释出处的全量对拍测试。
**但**：Agda 证明流程**未集成进本仓 CI**（本仓不构建 Agda，仅作对拍目标）。

---

## 2. 意图架构（intended）

```
╔═══════════ L-1 · 规范基座（外部仓库，权威）═══════════════════════╗
║  /data/work/discrete-mathematics —— Agda「律算合一」L0–L8         ║
║  /data/trit/pyBitNet —— 参考实现 + 《架构宪法 v1.1》              ║
╚═══════════════════════════╤═══════════════════════════════════════╝
                            │ 「照参考实现 + 逐条对拍」
                            ▼
╔═══════════ 内核 Kernel（Haskell）—— 推理中枢 ═════════════════════╗
║ ① 推理约束层（类型论 / 证明器）                       ★ 设计核心 ║
║    · 强类型范畴隔离：Trit / GF9 / GF27 / Z3r / Harmonic           ║
║    · T⁶ 几何验证门 t6Verify（缠绕 + Berry 相位连续）              ║
║    · 因果图 causalGraphStep（6×6 GF(3) 邻接）                     ║
║    · 五行推理链 wuxingForward（4 步 × heads + 可达标记）          ║
║    · 稳态判定 tailCycle（不落不动点）                             ║
║    · 依赖类型论 / Liquid Haskell 形式化（愿景）                   ║
║    【意图】对**任何**推理（含外部 API 返回）施加合法性约束        ║
║ ② 原生推理后端：CPU（三值/声子）· WebGPU（GPU）                   ║
║ ③ 模型接入层：外部 Provider · 本地 CPU adapter ·                  ║
║    草稿模型（speculative draft：小模型出草案 → 目标模型批量验证） ║
║    统一接口 llmChatToolsStream（流式是接口的一部分）              ║
║ ④ 协议面（servant）：/v1/{chat,completions|messages|responses}    ║
║    ± /stream · /providers* · provider 运行时选路                  ║
║ ⑤ 引擎原语：Plugin(Free monad) · Session · Agent FSM ·            ║
║    Tools · Event · Cache                                          ║
╚═══════════════════════════╤═══════════════════════════════════════╝
                            │ HTTP（OpenAI 兼容 /v1/*、/providers、/studio）
                            ▼
╔═══════ 编排 Orchestration（TypeScript）—— 工程手段 ═══════════════╗
║ 会话态 · plan/approval 决策门 · Cordis 插件服务化 · 并行/子代理 · ║
║ 事件总线+SSE · 工具裁决与执行 · provider 透传 · /studio 托管      ║
╚═══════════════════════════╤═══════════════════════════════════════╝
                            │ HTTP + SSE（:3456，Bearer）
                            ▼
╔═══════ 外壳 Shell —— Electron 解决跨平台渲染 ════════════════════╗
║ CLI（brick/haskeline）· Desktop（Electron+React）· Web（React）   ║
║ 外壳**派生**内核：stdout 握手 + stdin 租约 + 日志 stderr         ║
╚═══════════════════════════════════════════════════════════════════╝
```

---

## 3. 现状架构（actual）

```
╔═══ L-1 规范基座 ════════════════════════════════════════════════════╗
║ ✅ 两侧外部仓均在（Agda 含 Makefile/_build；pyBitNet 含宪法 v1.1）   ║
║ ⚠️ 仅作外部规范源：Agda 只出现在 test/Spec.hs 注释中；无 CI 证明流程 ║
╚═══════════════════════════╤═════════════════════════════════════════╝
                       ✅ 对拍已做（逐字照抄 + 全量对拍全绿）
                            ▼
╔═══════════════ 内核 Kernel（Haskell）═════════════════════════════╗
║ ① 推理约束层                                                        ║
║   ✅ 强类型范畴隔离（`SovereignTypes.hs` 341 行；类型化 API ≡ Int 版 ║
║      全量对拍绿）                                                   ║
║   ✅ `t6Verify` / `causalGraphStep` / `wuxingForward` / `tailCycle`  ║
║   ❌ 依赖类型论 / Liquid Haskell：**0 处代码**（仅 reference/ 文档） ║
║   ❌ ★ 约束不外向：只作用于本地三值前向；外部 API 走 provider 通道，  ║
║      与 T⁶/因果图**完全不相交** ★                                   ║
║ ② 原生推理后端                                                      ║
║   ✅ CPU：M1–M20（360=sic；真实全 60 层 292s / 峰值 41GiB / 0 fail） ║
║   ❌ CPU **不可达**：`createCPUAdapter` 零生产调用点；内核启动只跑   ║
║      `stubAdapter`（`startStubKernel` 硬编码）                      ║
║   ❌ WebGPU：1344 行 / **不在任何 cabal 组件**；`Buffer.hs:49`       ║
║      "not implemented in simulation"；FFI 未接 C 库                 ║
║ ③ 模型接入层                                                        ║
║   ✅ 外部：`adapterFor` 三 wire 分派 + 真流式 + tool 聚合 +         ║
║      provider 注册表（key 只存 env 名）                             ║
║   ✅ 本地：`createCPUAdapter`（实现完整，见"不可达"）               ║
║   ❌ 草稿模型（speculative draft）：**0 命中**                      ║
║   ✅ 统一流式接口 `llmChatToolsStream`（A4/A5 消除三套 SSE 实现）    ║
║ ④ 协议面：✅ 三 wire ± /stream（真 SSE：Raw + 逐帧 flush）·          ║
║      ✅ /providers*（P1–P8）                                        ║
║ ⑤ 引擎原语：✅ Plugin/Session/Agent FSM/Tools/Event                 ║
║   ❌ Cache：**70 行**（README 宣称"99%+"无实现）                    ║
║   ⚠️ `Orchestration.*`（199 行）：未接线遗迹                        ║
╚═══════════════════════════╤═════════════════════════════════════════╝
        ✅ HTTP 桥通（TS `Bridge/Haskell.ts` 222 行）
                            ▼
╔══════════ 编排 Orchestration（TypeScript）═══════════════════════╗
║ ✅ 会话态 stateStore（原子写+启动恢复）· plan/approval 决策门 ·    ║
║    Cordis 插件服务化（Registry/inject/五模式/watcher）·           ║
║    并行/子代理（1065 行）· 事件总线+SSE · 工具裁决执行(toolGuard) ·║
║    /studio 托管 ；115 vitest 用例                                 ║
╚═══════════════════════════╤═══════════════════════════════════════╝
                            ▼
╔══════════════ 外壳 Shell ════════════════════════════════════════╗
║ ✅ CLI（brick TUI + haskeline REPL；trha-cli-test 182/0）         ║
║ 🟡 Desktop（Electron 28 + React；U0–U3；linux deb 已验；win/mac   ║
║    未验；GUI 冒烟待宿主）                                          ║
║ ❌ Web：空壳（10 tsx）                                            ║
║ ✅ 宿主导出协议（握手/租约/日志 stderr）实测 11ms 释放            ║
╚═══════════════════════════════════════════════════════════════════╝
```

---

## 4. 偏差清单（按"离核心愿景的距离"排序）

| # | 意图 | 现状 | 性质 | 规模 |
|---|---|---|---|---|
| **D-1** | 推理约束**作用于外部 API 推理** | 约束层与 provider 通道**完全不相交** | ★ 架构缺口（核心愿景未落地） | 大 |
| **D-2** | 原生推理"内核自带" | 实现完整但**内核启动拿不到** | 装配缺口（一个入口） | 小 |
| **D-3** | 内核状态机承载**推理过程** | `Core.Agent.StateMachine` 是朴素 FSM（4 状态 5 命令）；真正的推理状态在 CPU 层 `T6State` | 概念未上浮 | 中 |
| **D-4** | 依赖类型论 / Liquid Haskell | 0 处代码 | 未开始 | 大 |
| **D-5** | 草稿模型（speculative draft） | 0 命中（概念出自 llama.cpp `speculative.md`） | 未开始 | 中 |
| **D-6** | WebGPU 后端 | 1344 行不在构建、simulation | 未接线 | 中 |
| **D-7** | Agda 作证明流程 | 仅注释里的对拍目标 | 流程未集成 | 中 |
| **D-8** | 缓存 | 70 行 vs README "99%+" | 宣称不符 | 小 |
| **D-9** | Haskell 侧 Orchestration 层 | 199 行未接线遗迹 | 应清理/标注 | 小 |

---

## 5. 实际状态分档（按"能不能被用起来"）

| 档 | 内容 | 判据 |
|---|---|---|
| **A 已建成且可达** | 外部模型接入（三 wire + 真流式 + provider 注册表）、协议面、引擎原语、TS 编排全功能、CLI 外壳、宿主导出协议 | 有测试 + 有调用点 + 端到端证据 |
| **B 已建成但不可达** | **本地三值推理（M1–M20）**、推理约束原语（T⁶/因果图/五行链） | 有测试、**无生产调用点** |
| **C 未接线** | WebGPU（1344 行）、`Presentation/**`（8 文件）、`Orchestration.*`（199 行遗迹） | 不在 cabal / 无引用 |
| **D 未开始** | 依赖类型论 / Liquid Haskell、草稿模型、**约束 ↔ 外部推理的连接层** | 0 命中 |
| **E 宣称与实现不符** | 缓存 99%（实 70 行）、README 的 WebGPU "Phase 3 ✅" | 文档 vs 实测 |

---

## 6. 任务原子分解（当前批次）

依赖关系：`P-4 → P-1(D-2) → [P-2(D-1) 需先澄清三定义]`

### 批次 1 · 落盘认知（本文档）
| ID | 原子 | 依赖 | 验收 |
|---|---|---|---|
| ✅ T1 | 新建本文档 | — | 文件存在、含 §1–§7 与附录 |
| ◻ T2 | 同步索引：`docs/README.md` + `QWEN.md` §Documentation + `docs/architecture/` 分类 | T1 | 两处索引均含本文档链接 |
| ◻ T3 | 提交（`docs:` 提交，纯文档，零代码改动） | T2 | `git status` 干净 |

### 批次 2 · D-2 让原生推理在内核可达（**本批核心**）
| ID | 原子 | 依赖 | 验收（可执行） |
|---|---|---|---|
| ◻ T4 | 拓扑扫描：`Core.Provider.Types` 的全部引用者与级联面（`API.Providers` / `API.ProviderRuntime` / Desktop `port/provider.ts` / scheduler 透传 / `test/Spec.hs`） | — | 列出引用清单与影响面 |
| ◻ T5 | 多路径推演并定案：**A** provider `kind` / **B** 启动参数 / **C** 启动配置 | T4 | 选定并记录权衡 |
| ◻ T6 | 红测：为"CPU backend 可被选中 + 引擎按路径复用（不重复 loadModel）"写 hspec | T5 | 测试失败（红） |
| ◻ T7 | 实现：装配入口 + **引擎缓存**（`MVar (Map FilePath InferenceEngine)`） | T6 | 测试转绿 |
| ◻ T8 | 端到端：HTTP `POST /v1/chat/completions` 带本地 backend → 由本地引擎回答 | T7 | 新增 e2e 用例通过 |
| ◻ T9 | 沙盒验证：`cabal build all` + `cabal test trha-test` + `cabal test trha-cli-test` + CLI 冒烟 | T8 | 全绿，无回归 |

### 批次 3 · P-2（D-1）约束 ↔ 外部推理 —— **待澄清后启动**
需要先定义：约束的作用点（请求侧/响应侧/双向）、失败行为（拒绝/降级/标注）、草稿模型的角色。

---

## 7. 待澄清（阻塞批次 3）

1. **「草稿模型」的角色**：本地三值模型作 draft、外部模型作 target？还是反之？它与"约束"是同一机制的两面吗？
2. **约束的作用点**：注入请求 / 校验响应 / 双向仲裁？
3. **约束失败的行为**：拒绝（4xx）/ 降级（回退本地）/ 标注（附警告继续）？
4. **Agda 的集成深度**：纳入本仓 CI（Haskell 实现对拍 Agda 才算过），还是维持"外部规范源"？

---

## 附录：复核命令

```bash
# 规范基座
ls /data/work/discrete-mathematics | head; head -25 /data/work/discrete-mathematics/README.md
head -70 /data/trit/pyBitNet/ARCHITECTURE_CONSTITUTION.md

# 约束原语（在 CPU 层内部）
grep -nE "^(t6Verify|causalGraphStep|wuxingForward) ::" -A3 src/Infrastructure/CPU/SovereignWuxingLayer.hs

# 原生推理不可达
grep -rn "createCPUAdapter" --include=*.hs src packages | grep -v dist-newstyle
sed -n '875,878p' src/API/Server.hs        # startStubKernel 硬编码 stubAdapter

# WebGPU 未接线
grep -rn "WebGPU" --include=*.cabal . | grep -v dist-newstyle   # → 无输出

# 草稿模型（0 命中）
grep -rniE "draft model|speculative|草稿模型" --include=*.hs --include=*.ts src packages

# 缓存实为 70 行
wc -l src/Core/Cache/*.hs
```
