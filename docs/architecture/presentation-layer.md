# Presentation 层设计

> ## ⚠️ 状态：**设计稿，未接线**（2026-09-13 核）
>
> - `src/Presentation/**`（8 个文件）**不在任何 cabal 组件**，全仓**无 `import Presentation.*`** → 该层**从未参与编译**。
> - 本文的**文件清单与现状不符**：下文列出的 `Web/{API,WebSocket,Static}.hs` 与 `TUI/{Render,Input,Theme}.hs` **共 6 个文件并不存在**（`[ -f ]` 逐项实测缺失）；`src/Presentation/Web/` 实际只有 `Main.hs`，`src/Presentation/TUI/` 实际只有 `Main.hs`。
> - **TUI 的真实实现不在本层**，而在外壳包 `packages/app/CLI/UI/**`（`UI.Render.*` / `UI.Theme` / `UI.Commands.Registry` / `UI.Brick`，由 `trha-cli-test` 182 用例覆盖）。
> - **Desktop 的真实实现也不在本层**，而在 `packages/app/Desktop`（Electron + React）。
>
> **结论**：本层是早期分层构想，其职责已被三个真实外壳各自实现。处置：**显式标注为未接线**（2026-09-13 所有者裁定）—— 不归档、不删除。状态分档见 `docs/plans/code-docs-reconciliation.md` §2 与 `docs/architecture/architecture-intended-vs-actual.md` §5（C 档）。

## 概述

> 以下为**设计稿原内容**（保留作历史与意图参考，**勿当成现状**）。

Presentation 层负责用户界面交互，包含三个子模块：

## 1. Desktop (Electron)

**位置**: `src/Presentation/Desktop/`

**职责**:
- Electron 桌面应用
- 跨平台窗口管理
- 原生菜单和快捷键
- 系统托盘集成
- 文件拖放支持

**技术栈**:
- Electron
- React/Vue (渲染进程)
- Node.js (主进程)

**关键文件**:
```
src/Presentation/Desktop/
├── Main.hs                    # 主进程入口
├── Window.hs                  # 窗口管理
├── Menu.hs                    # 菜单系统
├── Tray.hs                    # 系统托盘
├── IPC.hs                     # 进程间通信
└── Preload.hs                 # 预加载脚本
```

## 2. Web

**位置**: `src/Presentation/Web/`

**职责**:
- Web UI (React)
- 响应式设计
- WebSocket 实时通信
- REST API 集成

**关键文件**:
```
src/Presentation/Web/
├── Main.hs                    # Web 服务器入口
├── API.hs                     # REST API
├── WebSocket.hs               # WebSocket 处理
└── Static.hs                  # 静态资源
```

## 3. TUI

**位置**: `src/Presentation/TUI/`

**职责**:
- 终端 UI (Pi 风格)
- 差异渲染
- 键盘快捷键
- 进度条/动画

**关键文件**:
```
src/Presentation/TUI/
├── Main.hs                    # TUI 入口
├── Render.hs                  # 渲染引擎
├── Input.hs                   # 输入处理
└── Theme.hs                   # 主题配置
```

## 通信机制

```
用户操作
    │
    ▼
┌─────────────┐
│  Electron   │
│  主进程     │
└──────┬──────┘
       │ IPC (ipcMain/ipcRenderer)
       ▼
┌─────────────┐
│  渲染进程   │
│  (React)    │
└──────┬──────┘
       │ HTTP/WebSocket
       ▼
┌─────────────┐
│  调度层     │
│ (TypeScript)│
└──────┬──────┘
       │ HTTP/gRPC
       ▼
┌─────────────┐
│  核心引擎   │
│ (Haskell)   │
└─────────────┘
```

## 与 DeepSeek-Reasonix 的对应

DeepSeek-Reasonix 的 Electron 实现位于 `desktop/` 目录，包含：
- 窗口管理
- 菜单系统
- 系统托盘
- IPC 通信
- 预加载脚本

我们的架构将其抽象为 `Presentation/Desktop` 模块，通过 Haskell FFI 与核心引擎通信。