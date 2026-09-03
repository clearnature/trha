# gh-harness

A microkernel agent harness written in Haskell, inspired by the Cordis architecture, integrated with Pi's parallel capabilities, WebGPU acceleration, CPU optimization, TypeScript scheduling, Go-Haskell bridge, and static binary distribution.

## 项目结构

```
gh-harness/
├── src/                        # 核心引擎源代码 (Haskell)
│   ├── Core/                   # 核心引擎层
│   ├── LLM/                    # LLM 适配器层
│   ├── Infrastructure/         # 基础设施层
│   │   ├── Storage/            # 存储后端
│   │   ├── Network/            # 网络通信
│   │   ├── Sandbox/            # 沙箱隔离
│   │   ├── Telemetry/          # 遥测监控
│   │   ├── WebGPU/             # WebGPU 后端
│   │   └── CPU/                # CPU 后端
│   ├── Orchestration/          # 调度层桥接
│   └── Presentation/           # 表示层
├── packages/                   # 可安装包
│   ├── app/                    # 应用程序
│   │   ├── CLI/                # CLI 应用
│   │   ├── Desktop/            # 桌面应用
│   │   └── Web/                # Web 应用
│   ├── scheduler/              # 调度层 (TypeScript)
│   ├── sdk/                    # SDK 封装 (Haskell)
│   ├── go-haskell-bridge/      # Go-Haskell 桥接
│   └── haskell-network/        # Haskell 网络库
├── scripts/                    # 脚本
│   └── build/                  # 构建脚本
│       ├── static-build.sh     # 静态构建脚本
│       ├── test-multi-distro.sh # 多发行版测试
│       └── README.md           # 构建文档
├── .github/                    # GitHub Actions
│   └── workflows/
│       └── static-build.yml    # 静态构建工作流
├── Dockerfile.static           # 静态构建 Dockerfile
├── test/                       # 核心引擎测试
├── docs/                       # 项目文档
├── maps/                       # 架构图
├── benchmarks/                 # 性能基准
├── config/                     # 配置文件
└── gh-harness.cabal            # 核心引擎构建配置
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
10. **Go-Haskell 桥接**: 进程间优雅混合，高性能网络库
11. **静态二进制分发**: Alpine Linux + Musl 静态编译

## 构建

### 核心引擎 (Haskell)

```bash
cabal build
cabal test
```

### 静态二进制 (Alpine Linux)

```bash
# 使用 Docker 构建
docker build -f Dockerfile.static -t gh-harness:static .
docker run --rm -v $(pwd)/dist:/output gh-harness:static

# 或者直接在 Alpine Linux 上运行
./scripts/build/static-build.sh
```

### 多发行版测试

```bash
./scripts/build/test-multi-distro.sh
```

### GitHub Actions

项目配置了自动构建：
- 推送代码自动触发构建
- 创建 Release 自动构建并上传二进制
- 多发行版测试自动运行

## 分发

### 单文件二进制

- **平台**: Linux x86_64
- **格式**: 单文件二进制，无需依赖
- **大小**: ~50MB (静态链接)
- **兼容性**: 支持 Ubuntu、CentOS、Debian、Alpine、Fedora 等

### 下载

从 GitHub Releases 下载：

```bash
# 下载二进制
wget https://github.com/gh-harness/gh-harness/releases/latest/download/gh-harness-linux-x86_64.tar.gz

# 解压
tar -xzf gh-harness-linux-x86_64.tar.gz

# 运行
./gh-harness --help
```

## 架构

详见 [docs/architecture.md](docs/architecture.md)。

## 调度层文档

详见 [packages/scheduler/README.md](packages/scheduler/README.md)。

## SDK 文档

详见 [packages/sdk/docs/sdk-api.md](packages/sdk/docs/sdk-api.md)。

## Go-Haskell 桥接文档

详见 [packages/go-haskell-bridge/README.md](packages/go-haskell-bridge/README.md)。

## Haskell 网络库文档

详见 [packages/haskell-network/README.md](packages/haskell-network/README.md)。

## 构建脚本文档

详见 [scripts/build/README.md](scripts/build/README.md)。

## 技术栈

| 层 | 技术 | 职责 |
|---|---|---|
| **核心层** | Haskell/GHC + servant | 类型推理 + 缓存 |
| **SDK** | Haskell/GHC | API 封装 |
| **WebGPU** | WebGPU + WGSL | GPU 加速计算 |
| **CPU** | 多线程 + SIMD + BLAS | CPU 优化计算 |
| **调度层** | TypeScript + Cordis | 流程编排 + 并行 |
| **子代理** | TypeScript | 多 Agent 协作 |
| **Go-Haskell 桥接** | Go + Haskell | 进程间优雅混合 |
| **网络库** | Haskell Warp + Network | 高性能网络 |
| **静态编译** | Alpine Linux + Musl | 单文件二进制 |
| **表示层** | Electron/React/Pi TUI | 用户交互 |

## 下一步

1. **Phase 1**: 核心引擎 (Haskell) ✅
2. **Phase 2**: SDK 封装 ✅
3. **Phase 3**: WebGPU 后端 ✅
4. **Phase 4**: CPU 后端 ✅
5. **Phase 5**: 调度层 (TypeScript) ✅
6. **Phase 6**: 并行子代理 (Pi) ✅
7. **Phase 7**: 前端集成 ✅
8. **Phase 8**: Go-Haskell 桥接 ✅
9. **Phase 9**: Haskell 网络库 ✅
10. **Phase 10**: 静态二进制分发 ✅
