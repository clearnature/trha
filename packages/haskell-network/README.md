# Haskell Network Library

实现简单、容易维护、可重复利用现有组件的 Haskell 网络库。

## 概述

haskell-network 提供了：
- HTTP/1.1 + HTTP/2 + HTTP/3 支持
- 69k+ req/s 性能目标
- 保留 Go-Haskell 桥接
- 协议测试验证

## 架构

```
┌─────────────────────────────────────────────────────────────┐
│                    Haskell Network Library                  │
│   ┌────────────────────────────────────────────────────┐   │
│   │                    Core                            │   │
│   │  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐  │   │
│   │  │  Warp   │ │ Network │ │ Socket  │ │  Z-IO   │  │   │
│   │  │ Server  │ │  Base   │ │  Base   │ │ Toolkit │  │   │
│   │  └─────────┘ └─────────┘ └─────────┘ └─────────┘  │   │
│   │  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐  │   │
│   │  │  HTTP   │ │  HTTP   │ │  HTTP   │ │ Protocol│  │   │
│   │  │  1.1    │ │   2     │ │   3     │ │ Handler │  │   │
│   │  └─────────┘ └─────────┘ └─────────┘ └─────────┘  │   │
│   └────────────────────────────────────────────────────┘   │
├─────────────────────────────────────────────────────────────┤
│                    Bridge Layer                             │
│   ┌────────────────────────────────────────────────────┐   │
│   │  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐  │   │
│   │  │   Go    │ │  FFI    │ │ Shared  │ │ Channel │  │   │
│   │  │ Bridge  │ │ Bridge  │ │ Memory  │ │ Manager │  │   │
│   │  └─────────┘ └─────────┘ └─────────┘ └─────────┘  │   │
│   └────────────────────────────────────────────────────┘   │
├─────────────────────────────────────────────────────────────┤
│                    Application Layer                        │
│   ┌────────────────────────────────────────────────────┐   │
│   │  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐  │   │
│   │  │  HTTP   │ │  gRPC   │ │ WebSocket│ │  REST   │  │   │
│   │  │ Server  │ │ Server  │ │ Server  │ │  API    │  │   │
│   │  └─────────┘ └─────────┘ └─────────┘ └─────────┘  │   │
│   └────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

## 模块

### Core 模块

| 模块 | 文件 | 职责 |
|------|------|------|
| **Warp Server** | `Core/Warp.hs` | 高性能 Web 服务器 |
| **Network Base** | `Core/Network.hs` | 基础网络库 |
| **Socket Base** | `Core/Socket.hs` | 非阻塞 I/O 网络库 |
| **Z-IO Toolkit** | `Core/ZIO.hs` | 高性能 IO 工具包 |
| **HTTP 1.1** | `Core/HTTP1.hs` | HTTP/1.1 协议 |
| **HTTP 2** | `Core/HTTP2.hs` | HTTP/2 协议 |
| **HTTP 3** | `Core/HTTP3.hs` | HTTP/3 协议 |
| **Protocol Handler** | `Core/Protocol.hs` | 协议处理 |

### Bridge 模块

| 模块 | 文件 | 职责 |
|------|------|------|
| **Go Bridge** | `Bridge/Go.hs` | Go-Haskell 桥接 |
| **FFI Bridge** | `Bridge/FFI.hs` | FFI 桥接 |
| **Shared Memory** | `Bridge/Memory.hs` | 共享内存管理 |
| **Channel Manager** | `Bridge/Channel.hs` | Channel 管理 |

### Application 模块

| 模块 | 文件 | 职责 |
|------|------|------|
| **HTTP Server** | `App/HTTP.hs` | HTTP 服务器 |
| **gRPC Server** | `App/gRPC.hs` | gRPC 服务器 |
| **WebSocket Server** | `App/WebSocket.hs` | WebSocket 服务器 |
| **REST API** | `App/REST.hs` | REST API |

## 核心特性

1. **实现简单**: 选择容易维护的网络库
2. **可重复利用**: 复用现有组件
3. **HTTP/1.1 + HTTP/2 + HTTP/3**: 支持所有 HTTP 协议
4. **69k+ req/s**: 高性能目标
5. **Go-Haskell 桥接**: 保留桥接能力
6. **协议测试**: 完整的测试验证

## 使用示例

### Warp 服务器

```haskell
module Main where

import Network.Wai
import Network.Wai.Handler.Warp
import Network.HTTP.Types

main :: IO ()
main = do
    putStrLn "Starting Warp server on port 8080"
    run 8080 app

app :: Application
app request respond = do
    respond $ responseLBS
        status200
        [("Content-Type", "text/plain")]
        "Hello, World!"
```

### HTTP/2 支持

```haskell
module Main where

import Network.HTTP2.Server
import Network.HTTP2.Frame

main :: IO ()
main = do
    putStrLn "Starting HTTP/2 server on port 8443"
    runHTTP2Server 8443 app

app :: Request -> (Response -> IO ()) -> IO ()
app request respond = do
    respond $ response200 "Hello from HTTP/2"
```

### HTTP/3 支持

```haskell
module Main where

import Network.HTTP3.Server

main :: IO ()
main = do
    putStrLn "Starting HTTP/3 server on port 8443"
    runHTTP3Server 8443 app

app :: Request -> (Response -> IO ()) -> IO ()
app request respond = do
    respond $ response200 "Hello from HTTP/3"
```

### Go-Haskell 桥接

```haskell
module Main where

import Bridge.Go
import Bridge.FFI

main :: IO ()
main = do
    -- 创建 Go 桥接
    goBridge <- createGoBridge "localhost" 8080
    
    -- 调用 Go 函数
    result <- callGoFunction goBridge "getData" ["key1"]
    putStrLn $ "Result: " ++ show result
    
    -- 使用 FFI 桥接
    ffiResult <- callHaskellFunction "processData"
    putStrLn $ "FFI Result: " ++ show ffiResult
```

## 性能基准

### HTTP 服务吞吐量

| 框架 | 请求数/秒 | 语言 |
|------|-----------|------|
| **Apiary** | 69,056 | Haskell |
| **Gin** | 55,943 | Go |
| **Spock** | ~55,000 | Haskell |
| **Yesod** | ~55,000 | Haskell |

### 并发模型对比

| 模型 | 延迟 (ms) | 语言 |
|------|-----------|------|
| **绿色线程** | 2820 | Haskell |
| **Goroutine** | 629 | Go |
| **事件驱动** | ~3000 | Haskell |

## 构建

```bash
cd packages/haskell-network
cabal build
```

## 测试

```bash
cd packages/haskell-network
cabal test
```

## 技术栈

| 组件 | 技术 | 职责 |
|------|------|------|
| **Web 服务器** | Warp | 高性能 HTTP 服务器 |
| **网络库** | network | TCP/UDP/Unix Socket |
| **非阻塞 I/O** | socket | 高并发连接 |
| **IO 工具包** | Z-IO | 高性能 IO 操作 |
| **HTTP/2** | http2 | HTTP/2 协议支持 |
| **HTTP/3** | http3 | HTTP/3 协议支持 |
| **Go 桥接** | FFI | Go-Haskell 桥接 |

## 下一步

1. **Phase 1**: 实现 Warp 服务器
2. **Phase 2**: 实现 HTTP/2 支持
3. **Phase 3**: 实现 HTTP/3 支持
4. **Phase 4**: 实现 Go-Haskell 桥接
5. **Phase 5**: 性能优化