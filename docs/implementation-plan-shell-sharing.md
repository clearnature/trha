# CLI 和桌面共享代码实施计划

## 概述

基于 DeepSeek-Reasonix 的**内核-外壳分离**架构，实施 CLI 和桌面共享代码方案。

## 1. 项目结构调整

```
trha/
├── packages/
│   ├── core-engine/           # Haskell 核心引擎
│   │   ├── src/
│   │   │   ├── Core/
│   │   │   ├── LLM/
│   │   │   ├── Infrastructure/
│   │   │   └── Orchestration/
│   │   └── test/
│   │
│   ├── shared-frontend/       # 共享前端代码
│   │   ├── src/
│   │   │   ├── components/    # React 组件
│   │   │   ├── hooks/         # 自定义 hooks
│   │   │   ├── stores/        # 状态管理
│   │   │   ├── services/      # 服务层
│   │   │   └── types/         # 类型定义
│   │   └── test/
│   │
│   ├── electron-shell/        # Electron 外壳
│   │   ├── src/
│   │   │   ├── main/          # 主进程
│   │   │   ├── renderer/      # 渲染进程
│   │   │   └── preload/       # 预加载脚本
│   │   └── test/
│   │
│   ├── cli-shell/             # CLI 外壳
│   │   ├── src/
│   │   │   ├── commands/      # CLI 命令
│   │   │   ├── prompts/       # 交互式提示
│   │   │   └── output/        # 输出格式化
│   │   └── test/
│   │
│   └── web-shell/             # Web 外壳
│       ├── src/
│       │   ├── server/        # Web 服务器
│       │   └── static/        # 静态资源
│       └── test/
│
├── apps/
│   ├── desktop/               # 桌面应用入口
│   ├── cli/                   # CLI 应用入口
│   └── web/                   # Web 应用入口
│
└── docs/
```

## 2. 共享前端层设计

### 2.1 组件架构

```typescript
// packages/shared-frontend/src/components/index.ts
export { ChatView } from './Chat/ChatView'
export { SessionList } from './Session/SessionList'
export { ToolPanel } from './Tool/ToolPanel'
export { PlanView } from './Plan/PlanView'
export { SettingsPanel } from './Settings/SettingsPanel'
```

### 2.2 Shell 接口

```typescript
// packages/shared-frontend/src/shell/Shell.ts
export interface Shell {
  // 窗口管理
  showWindow(): void
  hideWindow(): void
  closeWindow(): void
  
  // 文件操作
  openFileDialog(): string | null
  saveFileDialog(): string | null
  
  // 通知
  showNotification(title: string, body: string): void
  
  // 通信
  sendHTTP(path: string, data?: any): Promise<any>
  sendSSE(path: string, callback: (data: any) => void): void
  
  // 平台特定
  getPlatform(): 'electron' | 'cli' | 'web'
  getCapabilities(): ShellCapabilities
}
```

### 2.3 Shell 工厂

```typescript
// packages/shared-frontend/src/shell/ShellFactory.ts
export function createShell(): Shell {
  const platform = detectPlatform()
  
  switch (platform) {
    case 'electron':
      return new ElectronShell()
    case 'cli':
      return new CLIShell()
    case 'web':
      return new WebShell()
    default:
      throw new Error(`Unsupported platform: ${platform}`)
  }
}
```

## 3. Electron 外壳实现

### 3.1 主进程

```typescript
// packages/electron-shell/src/main/main.ts
import { app, BrowserWindow, ipcMain } from 'electron'
import { createShell } from '@trha/shared-frontend'

class ElectronMain {
  private window: BrowserWindow
  private shell: Shell
  
  constructor() {
    this.shell = createShell()
    this.createWindow()
    this.setupIPC()
  }
  
  private createWindow(): void {
    this.window = new BrowserWindow({
      width: 1200,
      height: 800,
      webPreferences: {
        nodeIntegration: false,
        contextIsolation: true,
        preload: path.join(__dirname, 'preload.js')
      }
    })
    
    this.window.loadFile('index.html')
  }
  
  private setupIPC(): void {
    ipcMain.handle('shell:dialog:open', async () => {
      return this.shell.openFileDialog()
    })
    
    ipcMain.handle('shell:notification', async (event, title, body) => {
      return this.shell.showNotification(title, body)
    })
  }
}
```

### 3.2 预加载脚本

```typescript
// packages/electron-shell/src/preload/preload.ts
import { contextBridge, ipcRenderer } from 'electron'

contextBridge.exposeInMainWorld('shell', {
  openFileDialog: () => ipcRenderer.invoke('shell:dialog:open'),
  showNotification: (title, body) => ipcRenderer.invoke('shell:notification', title, body)
})
```

## 4. CLI 外壳实现

### 4.1 CLI 命令

```typescript
// packages/cli-shell/src/commands/chat.ts
import { Command } from 'commander'
import { createShell } from '@trha/shared-frontend'

export const chatCommand = new Command('chat')
  .description('Start interactive chat')
  .action(async () => {
    const shell = createShell()
    const chatView = new ChatView(shell)
    
    await chatView.start()
  })
```

### 4.2 交互式提示

```typescript
// packages/cli-shell/src/prompts/input.ts
import inquirer from 'inquirer'

export async function promptInput(message: string): Promise<string> {
  const { input } = await inquirer.prompt([
    {
      type: 'input',
      name: 'input',
      message
    }
  ])
  return input
}
```

## 5. 通信层实现

### 5.1 HTTP 客户端

```typescript
// packages/shared-frontend/src/services/HTTPClient.ts
export class HTTPClient {
  private baseUrl: string
  private cookie: string
  
  constructor(port: number) {
    this.baseUrl = `http://localhost:${port}`
  }
  
  async get<T>(path: string): Promise<T> {
    const response = await fetch(`${this.baseUrl}${path}`, {
      headers: {
        'Cookie': this.cookie
      }
    })
    return response.json()
  }
  
  async post<T>(path: string, data: any): Promise<T> {
    const response = await fetch(`${this.baseUrl}${path}`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Cookie': this.cookie
      },
      body: JSON.stringify(data)
    })
    return response.json()
  }
}
```

### 5.2 SSE 客户端

```typescript
// packages/shared-frontend/src/services/SSEClient.ts
export class SSEClient {
  private eventSource: EventSource
  
  constructor(port: number) {
    this.eventSource = new EventSource(`http://localhost:${port}/events`)
  }
  
  onMessage(callback: (data: any) => void): void {
    this.eventSource.onmessage = (event) => {
      callback(JSON.parse(event.data))
    }
  }
  
  close(): void {
    this.eventSource.close()
  }
}
```

## 6. 构建与发布

### 6.1 构建脚本

```json
{
  "scripts": {
    "build:shared": "tsc -p packages/shared-frontend/tsconfig.json",
    "build:electron": "electron-builder --config packages/electron-shell/electron-builder.json",
    "build:cli": "tsc -p packages/cli-shell/tsconfig.json",
    "build:web": "webpack --config packages/web-shell/webpack.config.js",
    "build:all": "npm run build:shared && npm run build:electron && npm run build:cli && npm run build:web"
  }
}
```

### 6.2 发布配置

```json
{
  "build": {
    "appId": "com.trha.desktop",
    "productName": "trha",
    "directories": {
      "output": "dist/electron"
    },
    "files": [
      "packages/shared-frontend/dist/**/*",
      "packages/electron-shell/dist/**/*"
    ],
    "mac": {
      "target": ["dmg", "zip"],
      "category": "public.app-category.developer-tools"
    },
    "win": {
      "target": ["nsis", "portable"]
    },
    "linux": {
      "target": ["deb", "AppImage"]
    }
  }
}
```

## 7. 测试策略

### 7.1 单元测试

```typescript
// packages/shared-frontend/src/components/__tests__/ChatView.test.tsx
import { render, screen } from '@testing-library/react'
import { ChatView } from '../Chat/ChatView'

describe('ChatView', () => {
  it('renders correctly', () => {
    const shell = createMockShell()
    render(<ChatView shell={shell} />)
    expect(screen.getByText('Chat')).toBeInTheDocument()
  })
})
```

### 7.2 集成测试

```typescript
// packages/electron-shell/src/__tests__/main.test.ts
import { ElectronMain } from '../main/main'

describe('ElectronMain', () => {
  it('creates window correctly', () => {
    const main = new ElectronMain()
    expect(main.window).toBeDefined()
  })
})
```

## 8. 时间线

### Phase 1: 基础架构 (1 周)
- [ ] 创建 monorepo 结构
- [ ] 实现 Shell 接口
- [ ] 实现共享前端组件骨架

### Phase 2: Electron 外壳 (1 周)
- [ ] 实现主进程
- [ ] 实现渲染进程
- [ ] 实现 IPC 通信

### Phase 3: CLI 外壳 (1 周)
- [ ] 实现 CLI 命令
- [ ] 实现交互式提示
- [ ] 实现输出格式化

### Phase 4: 集成测试 (1 周)
- [ ] 单元测试
- [ ] 集成测试
- [ ] 端到端测试

### Phase 5: 发布线 (1 周)
- [ ] 配置 electron-builder
- [ ] 实现三平台打包
- [ ] 实现自更新

## 9. 优势总结

1. **代码共享**: 90%+ 前端代码在三种外壳间共享
2. **统一用户体验**: 相同的界面和交互逻辑
3. **独立发布**: 每种外壳可独立发布和更新
4. **平台优化**: 每种外壳可针对平台优化
5. **易于维护**: 修改一处，三种外壳同步更新