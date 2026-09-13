# 归档：CPU 后端的 8 个孤立空壳模块

**归档日期**：2026-09-13（北京时间）
**归档决定**：所有者裁定「D. 归档孤儿 + 顺带实现 SIMD/BLAS」的**前半**（后半见文末，**尚未做**）
**原路径**：`src/Infrastructure/CPU/{Backend,Error,FFI,Main,Profile,Repack,Test,Thread}.hs`
**规模**：8 文件 / 486 行
**注意**：`SIMD` / `BLAS` **不在本目录**，它们仍在 `src/Infrastructure/CPU/` —— 理由见下文。

---

## 为什么归档（与旧 WebGPU 层同类）

`Backend.hs` 与先归档的 `archive/webgpu-legacy/` 是**同一种东西**：

| 位置 | 代码 | 事实 |
|---|---|---|
| `Backend.hs:52` `executeCompute` | `threadDelay 1000  -- 1ms delay` | 拿 sleep 假装算过（根本没有"计算"） |
| `Backend.hs:59` `synchronizeDevice` | `threadDelay 100; putStrLn "Device synchronized"` | 同上 |
| `Backend.hs:46` `shutdownBackend` | `putStrLn "CPU backend shutdown complete"` | 只打印 |

## 为什么可以安全移走（三条实测证据）

1. **不在构建**：这 8 个模块**不在 `trha.cabal` 的任何** library / executable / test-suite 里；
2. **无外部引用**：全仓 grep，引用者只有它们彼此（`Main` ↔ `Test` ↔ `Backend` ↔ `Thread` 互引）；
   `FFI` / `Main` / `Profile` / `Repack` / `Test` 更是**零引用**；
3. **不在真链上** —— 关键。真正的 CPU 推理链是：

```
LLM.Adapter.Interface        ← D-2 接通的 createCPUAdapter 在这里
  ├─ Infrastructure.CPU.Types
  └─ Infrastructure.CPU.Inference
        └─ Ops ──┬─ SIMD
                 └─ BLAS
```

   归档前后均 `cabal build all` → **EXIT=0 / 0 error**，证明移走这 8 个模块对构建与推理链
   **零影响**。

## 为什么 `SIMD` / `BLAS` 留在这里不归档

它们**在真链上**（`Ops` 引用它们，`Inference` 引用 `Ops`，`LLM.Adapter.Interface` 引用
`Inference`）。虽然目前是**标量桩**：

- `SIMD.hs:64` ——「Scalar implementation (would use SIMD intrinsics in production)」
- `BLAS.hs:37` ——「In production, would check for library presence」
- `Types.hs:113,133` —— `featureAVX512 = False -- Would check CPUID in production`

但"**在构建里的桩**"与"**不在构建的空壳**"是**两类问题**：动前者会影响真链，
必须先定依赖策略（见文末）。它们与 README 特性 7「CPU 优化：多线程 + SIMD + BLAS」
对应 —— 对账文档 `docs/plans/code-docs-reconciliation.md` §3 里那条
"BLAS/SIMD 仅有'检测 + 标量回退'" 说的就是它们。

## 取回

```bash
git mv archive/cpu-backend-legacy/*.hs src/Infrastructure/CPU/
```

Git 历史：`git log --follow archive/cpu-backend-legacy/Backend.hs`。

**取回前请知**：这些是空壳（`threadDelay` / 只打印），直接接线不会得到可用的 CPU 计算 ——
当前 `executeCompute` 甚至没有任何计算，只是 sleep 1ms。

## 未做完的另一半：实现 SIMD / BLAS（**尚未开始**）

它需要**先定依赖策略**（与当初决定 `wgpu-native` 是否进 `3rdparty/` 同类）：

| 项 | 前提 | 可选路径 |
|---|---|---|
| SIMD | 真实向量化 | (a) 新增 `cbits/*.c` 用 SSE/AVX intrinsics + FFI（最可控，但给仓库引入 C 层，与 wgpu-native 那次同类决策）；(b) GHC 的 SIMD primops（要求 LLVM 后端，本机当前是 NCG）；(c) Hackage 的 `simd` 包（间接要求 LLVM） |
| BLAS | 真 BLAS 库 | (a) 系统 OpenBLAS / MKL + `-lopenblas`（需先查本机是否有）；(b) 纯 Haskell 实现（性能难达预期） |

两条路都会给真链（`Ops`）引入**新依赖**，所以需要所有者先拍板 —— 这也是它没有和前一半
一起做完的原因。
