# 文件级完成跟踪（file completion tracking）

> 2026-09-13（北京时间）。记录本轮工作涉及**每个文件**的完成状态、**验证方式**与**证据**。
> 与 `plan-reconciliation.md`（计划 vs 现实）互补：
> 那份按**计划项**核对，本份按**文件**核对，且**必须**给出可执行的验证方式。

## 0. 总览

| 指标 | 值 |
|---|---|
| 本轮提交数 | **36**（`13b0b53^..HEAD`） |
| 涉及文件数 | 25 |
| `cabal build all` | **0 error / 0 warning** |
| `trha-test` | **189 examples, 0 failures**, 4 pending |
| `trha-cpu-test` | **99 examples, 0 failures**（会话开始时为 0） |
| `trha-webgpu-test` | **3 examples, 0 failures**（真机 GPU） |
| `trha-cli-test` | **182 examples, 0 failures** |

## 1. 新增文件（本轮从无到有）

| 文件 | 内容 | 验证方式 | 证据 |
|---|---|---|---|
| `src/Infrastructure/CPU/HoloPi.hs` | 全息 π 原子对 144/46（构造子不导出 ⇒ 禁止约分由类型保证） | `trha-cpu-test` C1·全息 π（3 例）+ **负面编译** ×2 | `e181d18`；`HoloPiArithmetic.hs`/`HoloPiReduce.hs` 编译必须失败 |
| `src/Infrastructure/CPU/HolographicSpace.hs` | GF(9) 内积空间（`hermitianIP`/`normSq`/`basisVec`/`basisAt`/`Orthogonal`）；共轭加在**第二个**参数 | `trha-cpu-test` C1·全息态与基模（+10 例，含穷举 GF(9)² 的 81 组钉住 `hermitian-conj-sym`） | `c417890` |
| `src/Infrastructure/CPU/ConstraintVerdict.hs` | 约束「采纳判定」：`projectToGF27` 投影桥 + `verdictOf` + `verdictOfWithState` | `trha-cpu-test` C5（+6 例）+ `trha-test` 端到端 ×4 | `b88f008` / `6f4baf5` |
| `test-cpu/Spec.hs` | CPU 侧数学正确性套件（C1/C2/C3/C4/C5 主题，**99 例**） | 自身即验证；`cabal test trha-cpu-test` | 本轮 17 次修改，0→99 |
| `test-cpu/negative/*.hs`（**9 个**） | 范畴隔离的**负面编译**用例（Trit/GF27、Z3r/GF27、Device/Buffer、HoloPi×2、GF9/GF27、Harmonic/GF27、Pv/[Int]、Z12/Q） | 每个都断言**必须编译失败** | `3847be6` / `7f090ef` |
| `docs/plans/verification-criteria.md` | 判据 C1–C5 + 覆盖进度表 + 三处实现事实 + 不变量清单 | 与代码/测试同步核对 | 本轮 7 次修改 |

## 2. 修改文件（本轮有实质改动）

| 文件 | 改动 | 验证方式 | 证据 |
|---|---|---|---|
| `src/Infrastructure/CPU/SovereignWuXing.hs` | 补 `generate`/`overcome`（五行相生/相克，权威有仓内无）+ 缠绕/Christoffel 相关导出 | `trha-cpu-test` C1·五行（6 例） | `13b0b53` |
| `src/Infrastructure/CPU/SovereignWuxingLayer.hs` | ① `fuseCoefInv = mkGF27 23`（0.1 系数**不再截断**，`div 10` → 域内乘 10⁻¹）；② 导出 `T6State(..)`/`t6Init`/`fuseCoefInv` | `trha-cpu-test`：单射/可逆/无零因子 + `[1..9]` 非零（3 例） | `f9d476f`（GF(27) 的 10⁻¹ = **23**，不是 Z/27 的 19） |
| `src/Core/Session/Types.hs` | `Session` 新增 `agentState :: IORef AgentState`（内核 FSM 进会话） | `trha-test` C1·会话层（Idle→Processing） | `020dc25` |
| `src/Core/Session/Manager.hs` | 新增 `setProjection`/`getProjection`/`projectionNames`（T1）+ `getAgentState`/`setAgentState`/`advanceAgent`（T3） | `trha-test`：projections 3 例 + FSM 1 例 | `910b90a` / `020dc25` |
| `src/Core/Agent/StateMachine.hs` | 导出 `AgentCommand (..)`（此前定义在模块内但未导出，会话层要用） | 编译期（未导出则 `trha-core` 编译失败） | `020dc25` |
| `src/API/Server.hs` | ① `ConstraintVerdict` 接线 + `constraintField`（D-1）；② `StartReq`/`StepReq` 手写 `FromJSON`（**修 400 契约 bug**）；③ `agentStepHandler`：写投影 + 推 FSM + 回显 | `trha-test` 端到端 ×6 | `25587ea` / `ca8afa6` / `8719f5` / `020dc25` |
| `trha.cabal` | 注册新模块（`HoloPi`/`HolographicSpace`/`ConstraintVerdict`）；`trha-api` 的 `other-modules` 27→29 并加**禁止删除**警示注释；`trha-cpu-test` 套件 | `cabal build all` 0 error；删任一项会**链接期**失败 | `ac7ba18` 等 |
| `test/Spec.hs` | D-1/C5 端到端（4 例）+ D-3 投影/FSM/端到端（5 例）+ projections 3 例 | `cabal test trha-test` | 181→189 |
| `test-webgpu/Spec.hs` | C3 四实现**同批全等**（`checkCase`：Haskell 标量 / C 标量 / AVX2 / GPU） | `cabal test trha-webgpu-test`（真机 AMD Navi 44 + Vulkan） | `84e9f6e` |
| `docs/architecture/architecture-intended-vs-actual.md` | D-1/D-2/D-3 关闭；D-6/D-7/D-8 据实更新；§5 分档 B→A；新增 §6b「已评估决定不做」 | 与代码/README 逐条核对 | `027d66c`/`914a174`/`3f688b3`/`c9ae3e8`/`70fccc5` |
| `README.md` | 去掉未经证实的「99%+ 命中率」；WebGPU 状态行同步 | 与 `src/Core/Cache/*` 实际能力一致 | `3f688b3` |

## 3. 判据覆盖（每条都有可执行验证）

| 判据 | 内容 | 验证方式 | 状态 |
|---|---|---|---|
| **C1** | 代数结构 ↔ 权威规范 | `trha-cpu-test` 9 个主题逐条对拍 Agda（五行/相位/缠绕/全息π/十二律/两序/分圆/商空间周期/HolographicSpace） | ✅ |
| **C2** | 类型不变量由**编译期**强制 | `test-cpu/negative/*.hs` **9 条**断言必须编译失败 | ✅ |
| **C3** | 多实现逐元素全等 | `trha-webgpu-test`：四实现（Haskell/C/AVX2/GPU）同批全等 | ✅ 4/4 |
| **C4** | 因果推理语义 | `trha-cpu-test` 8 项（t6Verify 的 Berry 判据/有状态/缠绕恒真冗余、argMaxIdx、adj 外积、不融合、传播、wuxingForward） | ✅ |
| **C5** | 约束 ↔ 外部 API 推理（D-1） | `trha-test` 端到端：响应带 `trha_constraint`，`warn` 时仍返回内容 | ✅ |

## 4. 已达成的架构闭合

| 项 | 内容 | 证据 |
|---|---|---|
| **D-1** | 约束作用于外部 API 推理 | 响应侧 `constraintField`；端到端 4 例 |
| **D-2** | 本地三值引擎可达（`kind="cpu"`） | `9a6dd6f` |
| **D-3** | 推理状态 + 内核 FSM 进会话 | `T6State` 经 `Session.projections`；`AgentState` 经 `Session.agentState`；`Core.Agent.StateMachine` **首次有生产调用点**（§5 B→A） |
| **D-9** | Haskell Orchestration 层 | 归档 `archive/orchestration/` |

## 5. 未完成 / 未验证（不掩盖）

| 项 | 实际情况 | 影响 |
|---|---|---|
| **生成层仍是占位** | `loadModel` 是 placeholder（恒 `Right ()`，**不读权重**）；`generateStream` 用 placeholder sampler（恒取 token 0，**不做 logits 采样**）。实测 `reply = "token_0" ×100` | **不能**做题（数学证明 / 编程）；端到端证明的只是**链路闭合** |
| **真实权重未接 `generate`** | `models/20260721-033421_step31000/data/1..20` **已**用于**推理内核**的 `WuxingLayerW`（有专门 describe），但**未**接入生成循环 | 生成层无真实前向 |
| **D-4** | 依赖类型论 / Liquid Haskell：0 处代码 | 未开始 |
| **D-5** | 草稿模型：概念已定（与约束同一机制的两面），实现未做 | 未开始 |
| **D-6** | WebGPU：已建成、有真机对拍，**未接生产推理路径** | 属 §5「C 未接线」 |
| **D-7** | Agda：对拍已成体系，但 Agda **未进 CI** | 待定集成深度 |
| **G3/G4** | 三端共享（`trha-ui` 提取、Desktop/Web 基线） | 未开始 |
| **G5** | 内核 HTTP 请求未纳入事件矩阵 | 未开始 |

## 6. 已知的构建不变量（勿动）

- **`trha-api` 的 `other-modules`（现有 29 项）禁止删除**：因 `trha-api` 与 `trha-llm`
  **共享 `hs-source-dirs: src`**，删任一项 ⇒ 单库构建 EXIT=0（骗过）但 `cabal build all`
  **链接期**失败。详见 `trha.cabal` 中该节的警示注释（含实测证据与分类对照表）。

## 7. 复核命令

```bash
cabal build all                      # 期望 0 error / 0 warning
cabal test trha-test                 # 189/0/4
cabal test trha-cpu-test             # 99/0
cabal test trha-webgpu-test          # 3/0（需 GPU，否则 pendingWith）
cabal test trha-cli-test             # 182/0
git log --oneline 13b0b53^..HEAD     # 本轮 36 个提交
```
