# trha CLI

CLI 交互界面，用于与 trha 代理系统交互。

## 概述

trha CLI 提供了：
- 命令行交互界面
- 会话管理
- 模型选择
- 工具调用日志
- 实时流式输出

## 架构

```
┌─────────────────────────────────────────────────────────────┐
│                    CLI Application                          │
│   ┌────────────────────────────────────────────────────┐   │
│   │                    UI Layer                        │   │
│   │  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐  │   │
│   │  │  Main   │ │Terminal │ │ Session │ │  Model  │  │   │
│   │  │  Loop   │ │   UI    │ │   UI    │ │   UI    │  │   │
│   │  └─────────┘ └─────────┘ └─────────┘ └─────────┘  │   │
│   └────────────────────────────────────────────────────┘   │
├─────────────────────────────────────────────────────────────┤
│                    Bridge Layer                             │
│   ┌────────────────────────────────────────────────────┐   │
│   │  ┌─────────┐ ┌─────────┐                          │   │
│   │  │Scheduler│ │  HTTP   │                          │   │
│   │  │ Bridge  │ │ Client  │                          │   │
│   │  └─────────┘ └─────────┘                          │   │
│   └────────────────────────────────────────────────────┘   │
├─────────────────────────────────────────────────────────────┤
│                    Core Layer                               │
│   ┌────────────────────────────────────────────────────┐   │
│   │  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐  │   │
│   │  │  Types  │ │ Client  │ │  HTTP   │ │ Config  │  │   │
│   │  │         │ │         │ │         │ │         │  │   │
│   │  └─────────┘ └─────────┘ └─────────┘ └─────────┘  │   │
│   └────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

## 模块

| 模块 | 文件 | 职责 |
|------|------|------|
| **Core.Types** | `Core/Types.hs` | 类型定义 |
| **Core.Client** | `Core/Client.hs` | CLI 客户端 |
| **Core.HTTP** | `Core/HTTP.hs` | HTTP 客户端 |
| **UI.Main** | `UI/Main.hs` | 主 UI 循环 |
| **UI.Terminal** | `UI/Terminal.hs` | 终端 UI |
| **UI.Session** | `UI/Session.hs` | 会话 UI |
| **UI.Model** | `UI/Model.hs` | 模型 UI |
| **Bridge.Scheduler** | `Bridge/Scheduler.hs` | 调度层桥接 |
| **Config.Settings** | `Config/Settings.hs` | 配置管理 |

## 核心特性

1. **命令行交互**: 支持基本命令和消息发送
2. **会话管理**: 创建、列表、删除会话
3. **模型选择**: 列出和选择可用模型
4. **工具调用日志**: 显示工具调用详情
5. **实时流式输出**: 流式显示 Agent 回复
6. **配置管理**: 加载和保存配置

## 使用示例

### 安装

```bash
# 方式一：开发链接（推荐开发期，指向当前构建产物）
ln -sf "$PWD/dist-newstyle/build/x86_64-linux/ghc-9.14.1/trha-0.1.0.0/x/trha/build/trha/trha" \
  ~/.local/bin/trha

# 方式二：安装到用户目录（cabal 全量安装）
cabal install exe:trha --installdir "$HOME/.local/bin" --overwrite-policy=always
```

确保 `~/.local/bin` 在 `PATH` 中。

### 基本使用

```bash
# 启动 CLI（REPL 模式；/quit 退出）
trha cli

# 启动 TUI（全屏终端界面；Ctrl+Q 直接退出，Ctrl+C 连按两次退出，Ctrl+D 空输入时退出）
trha tui

# 指定 TUI 主题（tokyo-night 深色 / light 浅色，默认读 settings.yaml 或 --theme）
trha --theme light tui

# TUI 内：输入 "/" 回车打开命令选择面板（Quick Picker）
#   ↑/↓ 移动 · 继续输入过滤 · Enter 执行 · Esc 关闭
# 例如输入 "/mo" 回车 → 选择面板列出 /model、/models → 回车执行

# 指定服务端与模型（默认读 ~/.trha/settings.yaml）
trha -h localhost -p 28433 -m deepseek-chat cli

# 发送消息
> /help

# 查看帮助 / 列出会话 / 列出模型
> /sessions
> /models

# 新建会话 / 切换模型
> /new
> /model deepseek-chat

# 退出与服务管理
> /quit                 # 只退出当前壳（Ctrl+Q 等价）
> /stop                # 提示确认
> /stop confirm        # 停止内核与 scheduler 并退出 TUI

# 键盘（与 Reasonix / Claude Code 一致）
#   Ctrl+C   运行中→中断 turn；输入非空→清空；空闲连按两次→退出（3 秒窗口）
#   Ctrl+D   空闲且输入为空→退出
#   Ctrl+Q   直接退出（保留旧习惯；部分终端的流控可能吞掉该键）

# 终端里（不需要 TUI）
trha status            # kernel: pid … (running) / scheduler: …
trha stop              # 两个都停（SIGTERM，校验 pid 身份）
trha stop scheduler    # 只停一个
```

### 配置目录 `~/.trha`

首次运行会自动创建以下结构（无需手工准备；目录 0700、文件 0600，仅本人可读写）：

```
~/.trha/
├── settings.yaml  # 用户配置（YAML，缺失时写入默认值，可直接编辑）
├── history        # REPL 命令历史（haskeline）
└── sessions/      # 本地会话 transcript
    └── <session-id>/
        └── transcript.jsonl   # 逐行 JSON 事件（session/user/assistant/tool/done/error）
```

> 旧版 `~/.trha/config.json` 已停用（不再读取），可自行删除。

### 配置分层

配置按以下优先级合并（高层覆盖低层的同名字段）：

1. 命令行 `--host/--port/--model`（最高）
2. 项目级 `./.trha/settings.yaml`（当前目录存在时生效，**不会**自动创建）
3. 用户级 `~/.trha/settings.yaml`（首跑自动生成默认值）
4. 内建默认值（最低）

例如 `~/.trha/settings.yaml` 设默认模型，某项目在项目根放 `./.trha/settings.yaml` 覆盖模型，命令行 `-m` 再覆盖。

配置文件内容：

```yaml
configHost: localhost
configMaxTokens: 4096
configModel: deepseek-chat
configPort: 28433   # orchestration layer (packages/scheduler)
configRetries: 3
configTimeout: 30000
configVerbose: false
configTheme: tokyo-night   # TUI 主题：tokyo-night | light（未知名称回退默认）
```

配置写入采用原子替换（临时文件 + rename），异常中断不会损坏文件；解析失败时打印 Warning 并回退默认值。

## 构建

```bash
cd app/CLI
cabal build
```

## 测试

```bash
cd app/CLI
cabal test
```

## 技术栈

| 组件 | 技术 | 职责 |
|------|------|------|
| **语言** | Haskell/GHC | 类型安全 |
| **HTTP** | http-client | HTTP 客户端 |
| **终端** | ansi-terminal | 终端 UI |
| **配置** | aeson | JSON 序列化 |

## 下一步

1. **Phase 7**: 前端集成 ✅
2. **Phase 8**: 并行子代理支持
3. **Phase 9**: 实时推理集成