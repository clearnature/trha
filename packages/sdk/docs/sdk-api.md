# gh-harness SDK API 文档

## 概述

gh-harness SDK 提供了与 gh-harness 核心引擎交互的 Haskell API。

## 安装

```bash
cabal install gh-harness-sdk
```

## 快速开始

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

## 核心模块

### Core.Types

核心类型定义，包括：
- `SessionId` - 会话标识符
- `AgentId` - 代理标识符
- `ToolName` - 工具名称
- `Message` - 消息类型
- `SessionEvent` - 会话事件
- `AgentState` - 代理状态
- `Tool` - 工具定义
- `ModelInfo` - 模型信息
- `Usage` - 使用统计
- `StreamChunk` - 流式响应块
- `SDKConfig` - SDK 配置
- `SDKError` - SDK 错误

### Core.Client

SDK 客户端，提供：
- `createClient` - 创建客户端
- `createClientWithConfig` - 使用自定义配置创建客户端
- 会话操作：`createSession`, `listSessions`, `getSession`, `deleteSession`
- 消息操作：`sendMessage`, `getMessages`, `streamMessages`
- 代理操作：`getAgentState`, `updateAgentState`
- 工具操作：`listTools`, `registerTool`, `unregisterTool`
- 模型操作：`listModels`, `getModel`
- 健康检查：`healthCheck`

### Core.HTTP

HTTP 客户端，提供：
- `createHTTPClient` - 创建 HTTP 客户端
- `httpGet` - GET 请求
- `httpPost` - POST 请求
- `httpPut` - PUT 请求
- `httpDelete` - DELETE 请求
- `buildUrl` - 构建 URL
- `parseResponse` - 解析响应

### Core.Server

服务器实现，提供：
- `createServer` - 创建服务器
- `startServer` - 启动服务器
- `API` - API 类型定义
- `handlers` - 请求处理器

### Core.Handlers

请求处理器，提供：
- 会话处理器
- 消息处理器
- 代理处理器
- 工具处理器
- 模型处理器
- 健康检查处理器

## 客户端模块

### Client.Session

会话客户端，提供：
- `createSessionClient` - 创建会话客户端
- `create` - 创建会话
- `list` - 列出会话
- `get` - 获取会话
- `delete` - 删除会话
- `sendMessage` - 发送消息
- `getMessages` - 获取消息
- `streamMessages` - 流式获取消息

### Client.Agent

代理客户端，提供：
- `createAgentClient` - 创建代理客户端
- `getState` - 获取代理状态
- `updateState` - 更新代理状态

### Client.Tool

工具客户端，提供：
- `createToolClient` - 创建工具客户端
- `list` - 列出工具
- `register` - 注册工具
- `unregister` - 注销工具

### Client.Model

模型客户端，提供：
- `createModelClient` - 创建模型客户端
- `list` - 列出模型
- `get` - 获取模型

## 工具模块

### Utils.Logger

日志工具，提供：
- `createLogger` - 创建日志器
- `logMessage` - 记录消息
- `logDebug` - 记录调试信息
- `logInfo` - 记录信息
- `logWarning` - 记录警告
- `logError` - 记录错误

### Utils.Retry

重试工具，提供：
- `defaultRetryConfig` - 默认重试配置
- `withRetry` - 带重试执行
- `withRetryAsync` - 异步重试执行

## 配置模块

### Types.Config

配置管理，提供：
- `loadConfig` - 加载配置
- `saveConfig` - 保存配置

## 错误处理

SDK 定义了以下错误类型：

```haskell
data SDKError
  = ConnectionError Text
  | AuthenticationError Text
  | ValidationError Text
  | ServerError Text
  | TimeoutError
  | UnknownError Text
```

## 示例

### 基本使用

```haskell
import Core.Types
import Core.Client
import Client.Session

main :: IO ()
main = do
  sdk <- createClient "localhost" 3000
  let sessionClient = createSessionClient sdk
  
  result <- Client.Session.create sessionClient
  case result of
    Right sessionId -> do
      response <- Client.Session.sendMessage sessionClient sessionId "Hello!"
      case response of
        Right chunk -> print chunk
        Left err -> print err
    Left err -> print err
```

### 使用自定义配置

```haskell
import Core.Types
import Core.Client

main :: IO ()
main = do
  let config = defaultConfig
        { configHost = "example.com"
        , configPort = 8080
        , configApiKey = Just "my-api-key"
        , configTimeout = 60
        , configRetries = 5
        }
  
  sdk <- createClientWithConfig config
  -- 使用 sdk...
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
cabal test
```

## 测试

```bash
cd sdk
cabal test
```