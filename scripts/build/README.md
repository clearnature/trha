# Static Build Scripts

用于构建 gh-harness 静态二进制的脚本。

## 概述

这些脚本使用 Alpine Linux + Musl 进行静态编译，生成可在大多数 Linux 系统上独立运行的单文件二进制。

## 脚本

| 脚本 | 文件 | 职责 |
|------|------|------|
| **static-build.sh** | `static-build.sh` | 主构建脚本 |
| **test-multi-distro.sh** | `test-multi-distro.sh` | 多发行版测试脚本 |

## 使用方法

### 静态构建

```bash
# 在 Alpine Linux 上运行
./scripts/build/static-build.sh

# 或者使用 Docker
docker build -f Dockerfile.static -t gh-harness:static .
docker run --rm -v $(pwd)/dist:/output gh-harness:static
```

### 多发行版测试

```bash
# 测试二进制在多个发行版上的兼容性
./scripts/build/test-multi-distro.sh
```

### GitHub Actions

项目配置了 GitHub Actions 自动构建：

1. **推送代码**：自动触发构建
2. **创建 Release**：自动构建并上传二进制
3. **多发行版测试**：自动在多个 Linux 发行版上测试

## 构建流程

1. **环境准备**：安装 Alpine Linux 依赖
2. **GHC 安装**：安装 Haskell 编译器
3. **Cabal 安装**：安装包管理器
4. **静态编译**：使用 Musl 进行静态链接
5. **二进制验证**：检查二进制是否静态链接
6. **打包分发**：创建 tar.gz 包

## 目标平台

- **Linux x86_64**：主要支持平台
- **Alpine Linux**：构建环境
- **Musl libc**：静态链接库

## 分发格式

- **单文件二进制**：无需依赖，直接运行
- **tar.gz 包**：包含二进制和 README

## 测试矩阵

| 发行版 | 版本 | 状态 |
|--------|------|------|
| Ubuntu | 22.04 | ✅ 支持 |
| CentOS | 7 | ✅ 支持 |
| Debian | 11 | ✅ 支持 |
| Alpine | 3.19 | ✅ 支持 |
| Fedora | 38 | ✅ 支持 |

## 故障排除

### 编译失败

```bash
# 检查 Alpine Linux 版本
cat /etc/alpine-release

# 检查 GHC 版本
ghc --version

# 检查 Cabal 版本
cabal --version
```

### 二进制无法运行

```bash
# 检查二进制类型
file dist/gh-harness

# 检查依赖
ldd dist/gh-harness

# 检查链接
readelf -d dist/gh-harness
```

### 多发行版测试失败

```bash
# 检查 Docker 是否运行
docker ps

# 手动测试特定发行版
docker run --rm -v $(pwd)/dist/gh-harness:/gh-harness ubuntu:22.04 /gh-harness --version
```

## 技术细节

### 静态链接

使用 `-optl-static -optl-pthread` 选项进行静态链接：

```bash
cabal build all --ghc-options='-optl-static -optl-pthread'
```

### Musl libc

Alpine Linux 使用 Musl libc，比 glibc 更小，更适合静态链接。

### 二进制大小

静态链接的二进制通常比动态链接的大，但无需依赖。

## 参考

- [Alpine Linux](https://alpinelinux.org/)
- [Musl libc](https://musl.libc.org/)
- [GHC Static Linking](https://wiki.haskell.org/Static_linking)
- [Cabal Static Build](https://cabal.readthedocs.io/en/latest/building.html#static-builds)