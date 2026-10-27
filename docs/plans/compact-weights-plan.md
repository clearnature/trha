# 紧凑权重计划（compact weights）

> **日期**：2026-10-27 ｜ **状态**：计划（P-12 用户裁定「先紧凑数组，再设门禁」）
> **台账 id**：`opt-b-compact-weights`

---

## 1. 问题（实测事实）

| 项 | 现状 |
|---|---|
| 旧流式路径（`brainStepToken`） | **≈ 222s/token**（每 token 重读 `.sov` + 重解包 300 块）；**已不作为默认路径** |
| 紧凑 C 链（`sovereignForwardFullCompact`） | **2.5s/token**（`trha-cpu-braintoken` 实测，3 token 均值；冷启动：load 3.2s + 预热 105.9s） |
| 整包装箱（`SovereignIntWeights`） | **~40GB**，超过本机 32GB commit 上限 ⇒ 不可常驻（旧路径） |
| 紧凑常驻（`SovereignIntWeightsC`） | **8.6GB RSS**（权重 ~5GB + 激活/临时；`/proc/self/status` 实测） |
| GPU 路径 | `engineGPU` 已接生产（`TRHA_GPU=1`，353ms/60 层 ≈ 5.1x CPU，hidden 与 CPU 逐元素一致）——**本计划只动 CPU 路径** |

## 2. 目标

1. **加载一次**：权重常驻内存，前向不重读文件、不重解包。
2. **紧凑表示**：`Data.Vector.Unboxed`（`Vector Double` 或 `Vector Float`），目标 RSS **≈ 2GB**。
3. **行为不变**：`forwardCompact` 与现有 `forward` 对同一输入**逐元素一致**（`test/cpu` 对拍）。
4. **门禁**：单 token ≤ **5s**（CPU；当前 **2.5s**，已达标），常驻 RSS ≤ **12GB**（当前 8.6GB）。GPU 路径不设此线。

## 3. 步骤

| 阶段 | 内容 | 验收 |
|---|---|---|
| **C1 类型** | `SovereignIntWeightsC`（`siwCEmbed` + `VS.Vector Int32` 扁平权重 + `[CIntLayer]`） | ✅ 已存在（2026-09-19） |
| **C2 加载器** | `loadWeightsSovC :: FilePath -> Int -> IO (Either String SovereignIntWeightsC)`：一次读 `.sov`、一次解包常驻 | ✅ 已存在；实测加载 3.2s |
| **C3 前向** | `sovereignForwardFullCompact`：每 token 不重读 `.sov`、不重建 `CIntLayer` | ✅ 已存在；与 `sovereignForwardFull` 逐 token 对拍（B1/B3 门禁） |
| **C4 接线** | `Brain.brainWeightsC` 优先于 `brainWeights`；`realStream` 走 `sovereignForwardFullCompact` | ✅ 已接线（`Inference.hs` 分支 ①） |
| **C5 门禁** | `benchmarks/cpu/BrainTokenBench.hs` → `trha-cpu-braintoken`：load / warmup / token 计时 + VmRSS | ✅ 实测 `load_ms=3202 warmup_ms=105952 token_ms=2549 rss_mb=8773` |

## 4. 风险与对策

| 风险 | 对策 |
|---|---|
| `Double` → `Float` 改变数值 | **先保持 Double**；Float 作为后续独立评估（需重新对拍） |
| `Unboxed` 的冻结/切片伪共享 | 用 `unsafeFreeze` + 每层独立切片；不改写已冻结向量 |
| 加载期内存峰值（读 + 解包同时存在） | 流式解包：逐层读入、解码、写入预分配的 `Mutable` 向量，读完即释放缓冲 |
| 与 GPU 路径的权重布局分叉 | 两者共用同一份 `.sov` 解析器（`loadWuxingFromSov`），只在内存布局上分叉 |
| 现有 `SovereignPacked` 仍被引用 | 保留旧路径作为对照，`forwardCompact` 通过测试后再切换默认 |

## 5. 结论（2026-10-27）

P-12 关闭：C1–C5 全部落地。默认路径已是紧凑 C 链（**2.5s/token、8.6GB RSS**），
旧流式路径（222s/token）与整包装箱（40GB）仅作对照保留。
门禁：`trha-cpu-braintoken` 单 token ≤5s、RSS ≤12GB（**均已达标**）。

## 6. 不做

- 不改模型格式（`.sov` 不变）
- 不改 GPU 内核（WGSL）
- 不引入新依赖（`vector` 已在依赖里）

## 6. 核实命令

```bash
# 现有权重表示与前向
rg -n "type .*Weights|loadWeightsFromSov|forward ::" src/llm/Infrastructure/CPU/*.hs | head
# 对拍入口
rg -n "forward|reportL" test/cpu/Spec.hs | head
# 当前计时记录
rg -n "222s|60 层|353ms" docs/architecture/architecture-intended-vs-actual.md
```
