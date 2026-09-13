# trha

A microkernel agent harness written in Haskell, inspired by the Cordis architecture, integrated with Pi's parallel capabilities, WebGPU acceleration, CPU optimization, TypeScript scheduling, and Desktop application.

## 项目结构

```
trha/
├── src/                        # 核心引擎源代码 (Haskell)
│   ├── Core/                   # 核心引擎层
│   ├── LLM/                    # LLM 适配器层
│   ├── Infrastructure/         # 基础设施层
│   ├── Orchestration/          # 调度层桥接
│   └── Presentation/           # 表示层
├── packages/                   # 可安装包
│   ├── app/                    # 应用程序
│   │   ├── CLI/                # CLI 应用
│   │   ├── Desktop/            # 桌面应用 (Electron + React)
│   │   └── Web/                # Web 应用
│   ├── scheduler/              # 调度层 (TypeScript)
│   ├── sdk/                    # SDK 封装 (Haskell)
│   ├── go-haskell-bridge/      # Go-Haskell 桥接
│   └── haskell-network/        # Haskell 网络库
├── scripts/                    # 脚本
│   ├── benchmark/              # 基准测试
│   ├── build/                  # 构建脚本
│   └── production/             # 生产环境脚本
├── benchmarks/                 # 冒烟测试
├── docs/                       # 文档
├── maps/                       # 架构图
└── trha.cabal                  # 核心引擎构建配置
```

## 核心特性

1. **类型驱动**: GHC 类型论推理，编译时保证正确性
2. **可热插拔**: Cordis 插件系统，运行时动态替换
3. **极致并行**: Pi 风格子代理，独立进程隔离
4. **高性能缓存**: Reasonix 级缓存，99%+ 命中率
5. **完整 SDK**: Haskell SDK，覆盖所有功能
6. **WebGPU 加速**: GPU 加速计算，参考 llama.cpp ggml-webgpu
7. **CPU 优化**: 多线程 + SIMD + BLAS，参考 llama.cpp ggml-cpu
8. **TypeScript 调度**: 插件系统 + 并行调度 + 子代理管理
9. **多 Agent 协作**: 独立进程子代理 + 通信协议 + 资源池
10. **桌面应用**: Electron + React 跨平台桌面应用

## 构建

### 核心引擎 (Haskell)

```bash
cabal build
cabal test
```

### 调度层 (TypeScript)

```bash
cd packages/scheduler
npm install
npm run build
npm test
```

### SDK (Haskell)

```bash
cd packages/sdk
cabal build
cabal test
```

### 桌面应用 (Electron + React)

```bash
cd packages/app/Desktop
npm install
npm run build
npm test
```

### CLI 应用

```bash
cd packages/app/CLI
cabal build
```

## 架构

详见 [docs/architecture/architecture.md](docs/architecture/architecture.md)。

## 调度层文档

详见 [packages/scheduler/README.md](packages/scheduler/README.md)。

## SDK 文档

详见 [packages/sdk/docs/sdk-api.md](packages/sdk/docs/sdk-api.md)。

## 桌面应用文档

详见 [packages/app/Desktop/README.md](packages/app/Desktop/README.md)。

## 技术栈

| 层 | 技术 | 职责 |
|---|---|---|
| **核心层** | Haskell/GHC + servant | 类型推理 + 缓存 |
| **SDK** | Haskell/GHC | API 封装 |
| **WebGPU** | WebGPU + WGSL | GPU 加速计算 |
| **CPU** | 多线程 + SIMD + BLAS | CPU 优化计算 |
| **调度层** | TypeScript + Cordis | 流程编排 + 并行 |
| **子代理** | TypeScript | 多 Agent 协作 |
| **桌面应用** | Electron + React | 跨平台桌面应用 |
| **网络库** | Haskell Warp + Network | 高性能网络 |
| **静态编译** | Alpine Linux + Musl | 单文件二进制 |

## 下一步

1. **Phase 1**: 核心引擎 (Haskell) ✅
2. **Phase 2**: SDK 封装 ✅
3. **Phase 3**: WebGPU 后端 ✅
4. **Phase 4**: CPU 后端 ✅
5. **Phase 5**: 调度层 (TypeScript) ✅
6. **Phase 6**: 并行子代理 (Pi) ✅
7. **Phase 7**: 桌面应用 (Electron + React) ✅
