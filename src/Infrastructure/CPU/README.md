# CPU Backend for trha

CPU 后端实现，用于在 CPU 上执行计算密集型任务。

## 概述

trha 的 CPU 后端提供了：
- 多线程支持
- SIMD 优化
- BLAS 集成
- 量化支持
- 架构特定优化

## 架构

```
┌─────────────────────────────────────────────────────────────┐
│                    CPU Backend                              │
│   ┌────────────────────────────────────────────────────┐   │
│   │                    Backend                         │   │
│   │  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐  │   │
│   │  │ Thread  │ │  SIMD   │ │  BLAS   │ │  Quant  │  │   │
│   │  │  Pool   │ │ Support │ │ Support │ │ Support │  │   │
│   │  └─────────┘ └─────────┘ └─────────┘ └─────────┘  │   │
│   │  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐  │   │
│   │  │   Ops   │ │ Profile │ │  Error  │ │   FFI   │  │   │
│   │  │ Support │ │ Manager │ │ Handler │ │ Bindings│  │   │
│   │  └─────────┘ └─────────┘ └─────────┘ └─────────┘  │   │
│   └────────────────────────────────────────────────────┘   │
├─────────────────────────────────────────────────────────────┤
│                    Architecture Support                     │
│   ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐        │
│   │  x86    │ │  ARM    │ │ RISC-V  │ │  Wasm   │        │
│   │  64-bit │ │  64-bit │ │  64-bit │ │         │        │
│   └─────────┘ └─────────┘ └─────────┘ └─────────┘        │
└─────────────────────────────────────────────────────────────┘
```

## 模块

| 模块 | 文件 | 职责 |
|------|------|------|
| **Types** | `Types.hs` | 类型定义 |
| **Backend** | `Backend.hs` | 后端实现 |
| **Thread** | `Thread.hs` | 线程管理 |
| **SIMD** | `SIMD.hs` | SIMD 操作 |
| **BLAS** | `BLAS.hs` | BLAS 操作 |
| **Quant** | `Quant.hs` | 量化操作 |
| **Ops** | `Ops.hs` | CPU 操作 |
| **Repack** | `Repack.hs` | 矩阵重排 |
| **Profile** | `Profile.hs` | 性能分析 |
| **Error** | `Error.hs` | 错误处理 |
| **FFI** | `FFI.hs` | FFI 绑定 |
| **Main** | `Main.hs` | 主入口 |
| **Test** | `Test.hs` | 测试 |

## 支持的架构

参考 llama.cpp 的 ggml-cpu 实现：

| 架构 | 状态 | 特性 |
|------|------|------|
| **x86_64** | ✅ 支持 | SSE, SSE2, SSE3, SSSE3, SSE4.1, SSE4.2, AVX, AVX2, AVX512, FMA, F16C |
| **ARM64** | ✅ 支持 | NEON, SVE, SVE2 |
| **ARM32** | ✅ 支持 | NEON |
| **RISC-V 64** | ✅ 支持 | V 扩展 |
| **LoongArch64** | ✅ 支持 | LSX, LASX |
| **PowerPC64** | ✅ 支持 | VSX |
| **S390X** | ✅ 支持 | VX |
| **Wasm** | ✅ 支持 | SIMD128 |

## SIMD 类型

| 类型 | 描述 | 支持的操作 |
|------|------|-----------|
| **SSE** | Streaming SIMD Extensions | 128-bit 浮点运算 |
| **SSE2** | SSE2 | 128-bit 整数和浮点运算 |
| **SSE3** | SSE3 | 水平运算 |
| **SSSE3** | Supplemental SSE3 | 字节重排 |
| **SSE4.1** | SSE4.1 | 点积、舍入 |
| **SSE4.2** | SSE4.2 | 字符串处理 |
| **AVX** | Advanced Vector Extensions | 256-bit 浮点运算 |
| **AVX2** | AVX2 | 256-bit 整数运算 |
| **AVX512** | AVX-512 | 512-bit 运算 |
| **NEON** | ARM NEON | 128-bit 运算 |
| **SVE** | Scalable Vector Extension | 可变长度向量 |
| **SVE2** | SVE2 | 增强 SVE |

## 量化类型

| 类型 | 描述 | 位宽 | 块大小 |
|------|------|------|--------|
| **F32** | 32-bit 浮点 | 32 | 1 |
| **F16** | 16-bit 浮点 | 16 | 1 |
| **Q4_0** | 4-bit 量化 | 4.5 | 32 |
| **Q4_1** | 4-bit 量化 | 5.0 | 32 |
| **Q5_0** | 5-bit 量化 | 5.5 | 32 |
| **Q5_1** | 5-bit 量化 | 6.0 | 32 |
| **Q8_0** | 8-bit 量化 | 8.5 | 32 |
| **Q8_1** | 8-bit 量化 | 9.0 | 32 |
| **Q2_K** | 2-bit K-quant | 3.0 | 256 |
| **Q3_K** | 3-bit K-quant | 4.0 | 256 |
| **Q4_K** | 4-bit K-quant | 5.0 | 256 |
| **Q5_K** | 5-bit K-quant | 6.0 | 256 |
| **Q6_K** | 6-bit K-quant | 7.0 | 256 |
| **IQ4_NL** | 4-bit 量化 | 4.5 | 32 |

## 使用示例

```haskell
import Infrastructure.CPU.Backend
import Infrastructure.CPU.Types
import Infrastructure.CPU.Thread
import Infrastructure.CPU.SIMD
import Infrastructure.CPU.Quant

main :: IO ()
main = do
  -- 创建后端
  result <- createCPUBackend defaultCPUConfig
  case result of
    Right backend -> do
      -- 初始化
      initializeBackend backend
      
      -- 创建线程池
      pool <- createThreadPool 4
      
      -- 执行计算
      -- ...
      
      -- 关闭
      destroyThreadPool pool
      shutdownBackend backend
    
    Left err -> putStrLn $ "Error: " ++ show err
```

## 构建

```bash
cd /home/yanli/work/gh--harness
cabal build
```

## 测试

```bash
cd /home/yanli/work/gh--harness
cabal test
```

## 参考

- [llama.cpp ggml-cpu](https://github.com/ggerganov/llama.cpp/tree/master/ggml/src/ggml-cpu)
- [GGML Library](https://github.com/ggerganov/ggml)
- [SIMD Programming](https://en.wikipedia.org/wiki/SIMD)