# gh-harness SDK

gh-harness 的 Haskell SDK，提供与核心引擎交互的 API。

## 项目结构

```
sdk/
├── src/                        # 源代码
│   ├── Core/                   # 核心模块
│   │   ├── Types.hs           # 类型定义
│   │   ├── Client.hs          # SDK 客户端
│   │   ├── HTTP.hs            # HTTP 客户端
│   │   ├── Server.hs          # 服务器实现
│   │   └── Handlers.hs        # 请求处理器
│   ├── Types/                  # 类型模块
│   │   └── Config.hs          # 配置管理
│   ├── Client/                 # 客户端模块
│   │   ├── Session.hs         # 会话客户端
│   │   ├── Agent.hs           # 代理客户端
│   │   ├── Tool.hs            # 工具客户端
│   │   └── Model.hs           # 模型客户端
│   ├── Utils/                  # 工具模块
│   │   ├── Logger.hs          # 日志工具
│   │   └── Retry.hs           # 重试工具
│   └── Server/                 # 服务器模块
│       └── Main.hs            # 服务器入口
├── test/                       # 测试
│   └── Spec.hs                # 测试规范
├── examples/                   # 示例
│   └── BasicUsage.hs          # 基本使用示例
├── docs/                       # 文档
│   └── sdk-api.md             # API 文档
├── gh-harness-sdk.cabal        # Cabal 构建配置
└── README.md                   # 本文件
```

## 核心特性

1. **类型安全**: Haskell 强类型系统保证 API 正确性
2. **完整 API**: 覆盖会话、代理、工具、模型等所有功能
3. **错误处理**: 完善的错误类型和处理机制
4. **可配置**: 支持自定义配置和重试策略
5. **可扩展**: 模块化设计，易于扩展

## 快速开始

### 安装

```bash
cabal install gh-harness-sdk
```

### 基本使用

```haskell
import Core.Types
import Core.Client
import Client.Session

main :: IO ()
main = do
  -- 创建 SDK 客户端
  sdk <- createClient "localhost" 3000
  
  -- 创建会话客户端
  let sessionClient = createSessionClient sdk
  
  -- 创建会话
  result <- Client.Session.create sessionClient
  case result of
    Right sessionId -> do
      putStrLn $ "Created session: " ++ sessionId
      
      -- 发送消息
      response <- Client.Session.sendMessage sessionClient sessionId "Hello!"
      case response of
        Right chunk -> putStrLn $ "Response: " ++ show chunk
        Left err -> putStrLn $ "Error: " ++ show err
      
    Left err -> putStrLn $ "Error: " ++ show err
```

### 服务器使用

```haskell
import Core.Server
import Core.Types

main :: IO ()
main = do
  let server = createServer 3000 "localhost"
  startServer server
```

## 构建

```bash
cd sdk
cabal build
```

## 测试

```bash
cd sdk
cabal test
```

## 文档

详见 [docs/sdk-api.md](docs/sdk-api.md)。

## 技术栈

| 组件 | 技术 | 职责 |
|------|------|------|
| **核心** | Haskell/GHC | 类型安全的 API |
| **HTTP** | http-client | HTTP 客户端 |
| **服务器** | servant + warp | REST API 服务器 |
| **JSON** | aeson | JSON 序列化 |
| **测试** | hspec + QuickCheck | 测试框架 |

## 下一步

1. **Phase 1**: 核心 API 实现 ✅
2. **Phase 2**: 服务器实现
3. **Phase 3**: 客户端实现
4. **Phase 4**: 工具实现
5. **Phase 5**: 文档和示例