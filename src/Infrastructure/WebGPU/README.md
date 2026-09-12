# WebGPU Backend for trha

WebGPU 后端实现，用于在 GPU 上执行计算密集型任务。

## 概述

WebGPU 是一个现代的、跨平台的图形和计算 API，用于在 GPU 上执行高性能计算。

trha 的 WebGPU 后端提供了：
- 设备管理
- 缓冲区管理
- 着色器管理
- 命令编码
- 计算操作
- 性能分析

## 架构

```
┌─────────────────────────────────────────────────────────────┐
│                    WebGPU Backend                           │
│   ┌────────────────────────────────────────────────────┐   │
│   │                    Backend                         │   │
│   │  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐  │   │
│   │  │ Device  │ │ Buffer  │ │ Shader  │ │ Command │  │   │
│   │  │ Manager │ │ Manager │ │ Manager │ │ Encoder │  │   │
│   │  └─────────┘ └─────────┘ └─────────┘ └─────────┘  │   │
│   │  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐  │   │
│   │  │ Compute │ │ Profile │ │  Error  │ │   FFI   │  │   │
│   │  │ Ops     │ │ Manager │ │ Handler │ │ Bindings│  │   │
│   │  └─────────┘ └─────────┘ └─────────┘ └─────────┘  │   │
│   └────────────────────────────────────────────────────┘   │
├─────────────────────────────────────────────────────────────┤
│                    WGSL Shaders                             │
│   ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐        │
│   │ MatMul  │ │ Softmax │ │ RMSNorm │ │  RoPE   │        │
│   │ Vector  │ │ Unary   │ │ Scale   │ │  Set    │        │
│   └─────────┘ └─────────┘ └─────────┘ └─────────┘        │
└─────────────────────────────────────────────────────────────┘
```

## 模块

| 模块 | 文件 | 职责 |
|------|------|------|
| **Types** | `Types.hs` | 类型定义 |
| **Device** | `Device.hs` | 设备管理 |
| **Buffer** | `Buffer.hs` | 缓冲区管理 |
| **Shader** | `Shader.hs` | 着色器管理 |
| **Command** | `Command.hs` | 命令编码 |
| **Compute** | `Compute.hs` | 计算操作 |
| **Backend** | `Backend.hs` | 后端实现 |
| **ShaderLib** | `ShaderLib.hs` | 着色器库 |
| **WGSL** | `WGSL.hs` | WGSL 着色器 |
| **Profile** | `Profile.hs` | 性能分析 |
| **Error** | `Error.hs` | 错误处理 |
| **FFI** | `FFI.hs` | FFI 绑定 |
| **Main** | `Main.hs` | 主入口 |
| **Test** | `Test.hs` | 测试 |

## WGSL 着色器

参考 llama.cpp 的 ggml-webgpu 实现：

| 着色器 | 文件 | 用途 |
|--------|------|------|
| **mul_mat_vec** | `mul_mat_vec.wgsl` | 矩阵-向量乘法 |
| **mul_mat_reg_tile** | `mul_mat_reg_tile.wgsl` | 矩阵乘法（寄存器分块） |
| **soft_max** | `soft_max.wgsl` | Softmax |
| **rms_norm_mul** | `rms_norm_mul.wgsl` | RMS 归一化 |
| **rope** | `rope.wgsl` | 旋转位置编码 |
| **unary** | `unary.wgsl` | 一元操作 |
| **scale** | `scale.wgsl` | 缩放操作 |
| **set** | `set.wgsl` | 设置操作 |
| **set_rows** | `set_rows.wgsl` | 设置行 |
| **pad** | `pad.wgsl` | 填充操作 |
| **repeat** | `repeat.wgsl` | 重复操作 |
| **row_norm** | `row_norm.wgsl` | 行归一化 |
| **sum_rows** | `sum_rows.wgsl` | 行求和 |
| **solve_tri** | `solve_tri.wgsl` | 三角求解 |
| **ssm_conv** | `ssm_conv.wgsl` | SSM 卷积 |
| **ssm_scan** | `ssm_scan.wgsl` | SSM 扫描 |
| **upscale** | `upscale.wgsl` | 上采样 |

## 使用示例

```haskell
import Infrastructure.WebGPU.Backend
import Infrastructure.WebGPU.Types
import Infrastructure.WebGPU.Device
import Infrastructure.WebGPU.Buffer
import Infrastructure.WebGPU.Shader
import Infrastructure.WebGPU.Command
import Infrastructure.WebGPU.Compute

main :: IO ()
main = do
  -- 创建后端
  result <- createWebGPUBackend defaultWebGPUConfig
  case result of
    Right backend -> do
      -- 初始化
      initializeBackend backend
      
      -- 创建缓冲区
      buffer <- createBuffer (backendDevice backend) 1024 [BufferUsageStorage]
      
      -- 执行计算
      -- ...
      
      -- 关闭
      shutdownBackend backend
    
    Left err -> putStrLn $ "Error: " ++ show err
```

## 构建

```bash
cd /home/yanli/work/trha
cabal build
```

## 测试

```bash
cd /home/yanli/work/trha
cabal test
```

## 参考

- [llama.cpp ggml-webgpu](https://github.com/ggerganov/llama.cpp/tree/master/ggml/src/ggml-webgpu)
- [WebGPU Specification](https://www.w3.org/TR/webgpu/)
- [WGSL Specification](https://www.w3.org/TR/WGSL/)