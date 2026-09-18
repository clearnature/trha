# 草稿模型微调计划（draft-model-finetune）

> **日期**：2026-09-19 · **性质**：主线计划（用户 2026-09-17 裁定：草稿模型基于依赖类型论展示群的数学体系，trha 保持通用 IDE 不收窄）
> **前置**：WebGPU 接线完成（D-6 闭合，`8020202`）→ 本地推理已 5.1x（353ms/60 层，GPU-only 闭环）
> **一句话**：让 trha 草稿模型最终能做到 Agda 的事（Γ⊢t:A 判定）——本计划是「数据 → 微调 → 验证」的路线图。

---

## 0. 当前能力边界（诚实基线，2026-09-19）

| 能力 | 状态 | 证据 |
|---|---|---|
| 真实 .sov 60 层前向 | ✅ 产出合法 token id | `trha-cpu-real60`（1.81s/token）、GPU-only（353ms/60 层，r-mu7cdlsf-mecbgq） |
| tokenize/detokenize | ✅ 真字符级（可逆、零越界 [0,1536)） | r-mu6p0yuj-1kmxri |
| **类型判定 Γ⊢t:A** | ❌ 未实现 | `verdictOf` 是**结构存在性检查**（FLT 真/篡改不可区分，j-mu6jiqc8-zxsm） |
| **证明项构造** | ❌ 未实现 | 无 |
| **定义相等判定** | ❌ 未实现 | 无 |
| 约束层（T⁶/因果图/五行） | ✅ 数学正确、C1–C5 全绿 | 111 例 0 failures |
| 微调本身 | ❌ 训练链未建 | 尚无微调脚本 |

**结论**：推理链路（前向+采样）是地基，但「推理 = 判定」还差三层（见 §3）。

## 2. 数据源（`/data/work/discrete-mathematics`）

| 资产 | 内容 | 用于 |
|---|---|---|
| `ChainZ3toZ12.agda`（249 行） | Z/3→Z/12 六段依赖类型论等词推理，**0 postulate** | 微调种子（"展示群"证明骨架） |
| `docs/techniques/pair-popping.md` | 替换证明技术（729→1 / 6561→1 / 729→59 str 化） | 结构形式化方法（用户强调：**不用穷举**） |
| `src/Sovereign/Coding/CyclicGF27.agda` | `*27-comm`（:238）等 | 数学权威对照 |
| `src/Sovereign/Structology/T6Rewrite.agda` | `--rewriting` 规则（div3k/mod3k） | 定义相等层（Agda 原生） |
| agda-stdlib（`/data/work/functional-programming/agda-stdlib`） | 539 文件 `--rewriting`、16 条 REWRITE | 大规模数据集（用户指定全量验证源） |

## 3. 三种机制（v1 原型在 `benchmarks/cpu/`，理解级）

| 机制 | 定义 | 现状 |
|---|---|---|
| **定理表示** | 定理 = 类型（Γ⊢t:A 的 A） | `algebra_chain_repr.py` 原型 |
| **证明生成** | 从表示生成证明项（pair-popping 替换） | `proof_generator.py` / `proof_plan_z3to12.json` |
| **证明验证器** | 判定生成项是否成立（替换步正确） | `proof_verifier.py`（链 6 段 PASS） |

> ⚠️ 原型是 Python 理解级，**不是交付物**；迁移方向是 Haskell（trha 内核）+ 大规模数据微调。

## 4. 微调路线（三步）

**Step A —— 数据链（建立可训练语料）**
- 源：discrete-mathematics 的 Agda 证明（ChainZ3toZ12 起，扩到 RingChain/FieldChain/ChainComplex）
- 转：证明 → (statement, proof-term) 对，tokenize 后进训练样本
- 验证：tokenize 往返可逆（已有）+ agda-stdlib 大规模语料对账

**Step B —— 微调协议**
- 方法：不同于 LLM 的通用微调（用户：架构/训练方法「和他们不一样」）
- 路线：展示群结构为内建偏置（GF(27) 扩张塔 GF(3)→GF(9)，非 27 标量环表）
- 训练目标：从「拟合」改为「**相位对齐**」（用户理论：训练 = 对齐，非拟合）

**Step C —— 判定能力验证**
- 判据：Γ⊢t:A 的正确判定（负向控制：坏证明必须拒绝）
- 对照：agda-stdlib 全量验证（用户指定）
- 每步一条门禁 + 回执

## 5. 立即待办（下一步可开工）

1. [ ] 建立微调数据 ETL（ChainZ3toZ12.agda → 训练对）——**第一个可开工项**
2. [ ] 决定训练后端（Python/venv pytorch-cpu or 原生）——待人类裁决
3. [ ] 与用户确认 Step B 的「相位对齐」目标函数形式

## 6. 相关
- D-5（architecture-intended-vs-actual.md）：草稿模型定义（用户裁定：本地 CPU/WebGPU 大脑，非 speculative decoding）
- j-mu6nr3i2-yk7b：方向修正（trha 不收窄）
- 上一批交接 j-mu7dcvgt-yad8