# trha Desktop Application

Electron + React 桌面应用程序，用于与 trha 代理系统交互。

## 概述

trha Desktop 提供了：
- 图形化用户界面
- 会话管理
- 模型选择
- 工具调用
- 设置面板

## 架构

```
packages/app/Desktop/
├── src/
│   ├── main/                  # Electron 主进程
│   │   └── index.ts           # 主进程入口
│   ├── renderer/              # React 渲染进程
│   │   ├── App.tsx            # 主应用组件
│   │   ├── index.tsx          # 渲染进程入口
│   │   ├── components/        # UI 组件
│   │   │   ├── Sidebar.tsx    # 侧边栏
│   │   │   ├── ChatView.tsx   # 聊天视图
│   │   │   └── SettingsPanel.tsx # 设置面板
│   │   ├── stores/            # 状态管理
│   │   │   └── appStore.ts    # 应用状态
│   │   └── styles/            # 样式
│   │       └── global.css     # 全局样式
│   ├── preload/               # 预加载脚本
│   │   └── index.ts           # 预加载入口
│   └── shared/                # 共享类型
│       └── types.ts           # 类型定义
├── public/                    # 静态资源
│   └── index.html             # HTML 模板
├── test/                      # 测试
│   └── app.test.ts            # 测试用例
├── package.json               # npm 配置
├── tsconfig.json              # TypeScript 配置
├── tsconfig.main.json         # 主进程 TypeScript 配置
├── vite.config.ts             # Vite 配置
└── README.md                  # 本文件
```

## 核心特性

1. **Electron 主进程**: 窗口管理、IPC 通信、系统集成
2. **React 渲染进程**: 响应式 UI、状态管理、组件化
3. **预加载脚本**: 安全的 IPC 桥接
4. **状态管理**: Zustand 状态管理
5. **主题支持**: 明暗主题切换
6. **国际化**: 多语言支持

## 构建

### 安装依赖

```bash
cd packages/app/Desktop
npm install
```

### 开发模式

```bash
npm run dev
```

### 构建生产版本

```bash
npm run build
```

### 启动应用

```bash
npm start
```

### 运行测试

```bash
npm test
```

## 核心组件

### Sidebar

侧边栏组件，包含：
- 会话列表
- 新建会话按钮
- 设置按钮

### ChatView

聊天视图组件，包含：
- 消息列表
- 输入框
- 发送按钮
- 状态显示

### SettingsPanel

设置面板组件，包含：
- 主题切换
- 模型选择
- 服务器配置
- 语言设置

## 状态管理

使用 Zustand 进行状态管理：

```typescript
import { useAppStore } from './stores/appStore';

const { sessions, addSession, currentSession, setCurrentSession } = useAppStore();
```

## IPC 通信

通过预加载脚本进行安全的 IPC 通信：

```typescript
// 渲染进程
const version = await window.electronAPI.getAppVersion();

// 主进程
ipcMain.handle('get-app-version', () => {
  return app.getVersion();
});
```

## 主题

支持明暗主题切换：

```typescript
const { theme, setTheme } = useAppStore();
setTheme('dark');
```

## 国际化

支持多语言：

```typescript
const { config, setConfig } = useAppStore();
setConfig({ language: 'zh' });
```

## 测试

```bash
npm test
```

## 技术栈

| 组件 | 技术 | 职责 |
|------|------|------|
| **主进程** | Electron | 窗口管理、IPC |
| **渲染进程** | React + TypeScript | UI 组件 |
| **状态管理** | Zustand | 应用状态 |
| **构建工具** | Vite | 快速构建 |
| **测试** | Vitest | 单元测试 |
| **样式** | CSS | 界面样式 |

## 下一步

1. **集成调度层**: 连接 TypeScript 调度层
2. **实现 IPC 通信**: 实现与后端的通信
3. **添加更多组件**: 工具面板、模型选择器等
4. **性能优化**: 启动时间、内存使用优化