# Go-Haskell Bridge

> **已归档（2026-10-27）**：本目录原计划复用 Reasonix 的 Go 桥代码，现确认不需要。
> 根构建引用 0 次、无业务逻辑；保留在 `archive/` 仅作历史参考。
> 相关记录见 `docs/plans/improvement-plan-2026-10-27.md`（P-14）。

Go 和 Haskell 的进程间优雅混合，通过高性能网络库实现高频交互。

## 概述

go-haskell-bridge 提供了：
- 进程间通信 (HTTP/gRPC)
- 高性能网络库
- 统一错误处理
- 共享内存管理

## 架构

```
┌─────────────────────────────────────────────────────────────┐
│                    Go Service                               │
│   ┌────────────────────────────────────────────────────┐   │
│   │  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐  │   │
│   │  │  HTTP   │ │  gRPC   │ │ Channel │ │ Goroutine│  │   │
│   │  │ Server  │ │ Server  │ │ Manager │ │  Pool    │  │   │
│   │  └─────────┘ └─────────┘ └─────────┘ └─────────┘  │   │
│   │  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐  │   │
│   │  │  Error  │ │ Memory  │ │ Protocol│ │ Serializer│  │   │
│   │  │ Handler │ │ Manager │ │ Handler │ │          │  │   │
│   │  └─────────┘ └─────────┘ └─────────┘ └─────────┘  │   │
│   └────────────────────────────────────────────────────┘   │
├─────────────────────────────────────────────────────────────┤
│                    Communication Layer                      │
│   ┌─────────┐ ┌─────────┐ ┌─────────┐                    │
│   │  HTTP   │ │  gRPC   │ │ Shared  │                    │
│   │  JSON   │ │ Protobuf│ │ Memory  │                    │
│   └─────────┘ └─────────┘ └─────────┘                    │
├─────────────────────────────────────────────────────────────┤
│                    Haskell Service                          │
│   ┌────────────────────────────────────────────────────┐   │
│   │  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐  │   │
│   │  │  HTTP   │ │  gRPC   │ │  STM    │ │  FFI    │  │   │
│   │  │ Client  │ │ Client  │ │ Manager │ │ Bridge  │  │   │
│   │  └─────────┘ └─────────┘ └─────────┘ └─────────┘  │   │
│   │  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐  │   │
│   │  │  Error  │ │ Memory  │ │ Protocol│ │ Serializer│  │   │
│   │  │ Handler │ │ Manager │ │ Handler │ │          │  │   │
│   │  └─────────┘ └─────────┘ └─────────┘ └─────────┘  │   │
│   └────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

## 模块

### Go 模块

| 模块 | 文件 | 职责 |
|------|------|------|
| **HTTP Server** | `go/http/server.go` | HTTP 服务器 |
| **gRPC Server** | `go/grpc/server.go` | gRPC 服务器 |
| **Channel Manager** | `go/channel/manager.go` | Channel 管理 |
| **Goroutine Pool** | `go/goroutine/pool.go` | Goroutine 池 |
| **Error Handler** | `go/error/handler.go` | 错误处理 |
| **Memory Manager** | `go/memory/manager.go` | 内存管理 |
| **Protocol Handler** | `go/protocol/handler.go` | 协议处理 |
| **Serializer** | `go/serializer/serializer.go` | 序列化 |

### Haskell 模块

| 模块 | 文件 | 职责 |
|------|------|------|
| **HTTP Client** | `haskell/HTTP/Client.hs` | HTTP 客户端 |
| **gRPC Client** | `haskell/gRPC/Client.hs` | gRPC 客户端 |
| **STM Manager** | `haskell/STM/Manager.hs` | STM 管理 |
| **FFI Bridge** | `haskell/FFI/Bridge.hs` | FFI 桥接 |
| **Error Handler** | `haskell/Error/Handler.hs` | 错误处理 |
| **Memory Manager** | `haskell/Memory/Manager.hs` | 内存管理 |
| **Protocol Handler** | `haskell/Protocol/Handler.hs` | 协议处理 |
| **Serializer** | `haskell/Serializer/Serializer.hs` | 序列化 |

## 核心特性

1. **进程间通信**: HTTP/gRPC 高频交互
2. **高性能网络库**: Go 的高性能网络库
3. **统一错误处理**: Go 和 Haskell 使用统一的错误处理机制
4. **共享内存管理**: Go 和 Haskell 共享内存空间
5. **协议处理**: 支持 JSON/Protobuf 序列化
6. **Channel 管理**: Go 的 channel 和 Haskell 的 STM 集成

## 使用示例

### Go 端

```go
package main

import (
    "github.com/clearnature/trha/packages/go-haskell-bridge/go/http"
    "github.com/clearnature/trha/packages/go-haskell-bridge/go/grpc"
)

func main() {
    // 启动 HTTP 服务器
    httpServer := http.NewServer(":8080")
    go httpServer.Start()

    // 启动 gRPC 服务器
    grpcServer := grpc.NewServer(":9090")
    go grpcServer.Start()

    // 等待信号
    select {}
}
```

### Haskell 端

```haskell
module Main where

import HTTP.Client
import gRPC.Client
import STM.Manager

main :: IO ()
main = do
    -- 创建 HTTP 客户端
    httpClient <- createHTTPClient "http://localhost:8080"
    
    -- 创建 gRPC 客户端
    grpcClient <- createGRPCClient "localhost:9090"
    
    -- 创建 STM 管理器
    stmManager <- createSTMManager
    
    -- 使用客户端
    response <- httpGet httpClient "/api/data"
    putStrLn $ "Response: " ++ show response
```

## 通信协议

### HTTP JSON

```json
{
    "method": "GET",
    "path": "/api/data",
    "headers": {
        "Content-Type": "application/json"
    },
    "body": null
}
```

### gRPC Protobuf

```protobuf
syntax = "proto3";

service HaskellBridge {
    rpc GetData (GetDataRequest) returns (GetDataResponse);
    rpc SetData (SetDataRequest) returns (SetDataResponse);
}

message GetDataRequest {
    string key = 1;
}

message GetDataResponse {
    string value = 1;
    int32 code = 2;
    string error = 3;
}
```

## 错误处理

### 统一错误格式

```json
{
    "code": 500,
    "message": "Internal server error",
    "details": {
        "type": "ServerError",
        "reason": "Database connection failed",
        "timestamp": "2026-09-04T00:00:00Z"
    }
}
```

### 错误传播

1. Go 端捕获错误
2. 序列化为统一格式
3. 通过 HTTP/gRPC 发送到 Haskell 端
4. Haskell 端反序列化并处理

## 共享内存管理

### 内存映射

```go
// Go 端
mem, err := mmap.Open("/dev/shm/trha", mmap.READ|mmap.WRITE)
if err != nil {
    log.Fatal(err)
}
defer mem.Close()

// 写入数据
copy(mem.Data(), []byte("Hello from Go"))
```

```haskell
-- Haskell 端
mem <- openSharedMemory "/dev/shm/trha" ReadWriteMode
content <- readSharedMemory mem
putStrLn $ "Content: " ++ show content
```

### 引用计数

```go
// Go 端
ref := NewRefCounted(data)
ref.Increment()
defer ref.Decrement()
```

```haskell
-- Haskell 端
ref <- newRefCounted data
incrementRefCount ref
-- 使用数据
decrementRefCount ref
```

## 构建

### Go 端

```bash
cd packages/go-haskell-bridge/go
go build
```

### Haskell 端

```bash
cd packages/go-haskell-bridge/haskell
cabal build
```

## 测试

### Go 端

```bash
cd packages/go-haskell-bridge/go
go test
```

### Haskell 端

```bash
cd packages/go-haskell-bridge/haskell
cabal test
```

## 技术栈

| 组件 | 技术 | 职责 |
|------|------|------|
| **Go** | Go 1.21+ | 高性能网络库 |
| **Haskell** | GHC 9.4+ | 类型安全的函数式编程 |
| **HTTP** | net/http (Go), http-client (Haskell) | HTTP 通信 |
| **gRPC** | grpc-go (Go), grpc-haskell (Haskell) | gRPC 通信 |
| **序列化** | encoding/json (Go), aeson (Haskell) | JSON 序列化 |
| **序列化** | protobuf (Go), proto-lens (Haskell) | Protobuf 序列化 |
| **内存** | mmap (Go), mmap (Haskell) | 共享内存 |

## 下一步

1. **Phase 1**: 实现 HTTP 通信
2. **Phase 2**: 实现 gRPC 通信
3. **Phase 3**: 实现共享内存
4. **Phase 4**: 实现统一错误处理
5. **Phase 5**: 性能优化