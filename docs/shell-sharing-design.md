# CLI 和桌面共享代码设计

## 核心思想

借鉴 DeepSeek-Reasonix 的**内核-外壳分离**架构，实现 CLI 和桌面共享同一份前端代码。

## 架构分层

```
┌─────────────────────────────────────────────────────────────┐
│                    外壳层 (Shell Layer)                      │
│   ┌──────────────┐  ┌──────────────┐  ┌──────────────┐     │
│   │   Electron   │  │    CLI       │  │    Web       │     │
│   │   Desktop    │  │   (Terminal) │  │   (Browser)  │     │
│   └──────┬───────┘  └──────┬───────┘  └──────┬───────┘     │
│          │                 │                 │              │
│          └─────────────────┼─────────────────┘              │
│                            │ HTTP/SSE/IPC                   │
├────────────────────────────┼────────────────────────────────┤
│                    共享前端层 (Shared Frontend)               │
│   ┌────────────────────────┴────────────────────────────┐   │
│   │                TypeScript/React                      │   │
│   │  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐  │   │
│   │  │  Chat   │ │ Session │ │  Tool   │ │  Plan   │  │   │
│   │  │  View   │ │  List   │ │  Panel  │ │  View   │  │   │
│   │  └─────────┘ └─────────┘ └─────────┘ └─────────┘  │   │
│   │  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐  │   │
│   │  │ Settings│ │ Sidebar │ │ Toolbar │ │ Status  │  │   │
│   │  │         │ │         │ │         │ │  Bar    │  │   │
│   │  └─────────┘ └─────────┘ └─────────┘ └─────────┘  │   │
│   └────────────────────────────────────────────────────┘   │
├─────────────────────────────────────────────────────────────┤
│                    核心引擎层 (Core Engine)                   │
│   ┌────────────────────────────────────────────────────┐   │
│   │                    Haskell/GHC                      │   │
│   │  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐  │   │
│   │  │  Agent  │ │ Session │ │  Tool   │ │  Cache  │  │   │
│   │  │  Loop   │ │  Log    │ │ Registry│ │ Engine  │  │   │
│   │  └─────────┘ └─────────┘ └─────────┘ └─────────┘  │   │
│   └────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

## 外壳适配层

### 1. Electron 外壳

```typescript
// src/Presentation/Desktop/Shell.ts
export class ElectronShell implements Shell {
  private window: BrowserWindow
  private ipc: IPCChannel
  
  constructor() {
    this.window = new BrowserWindow({
      webPreferences: {
        nodeIntegration: false,
        contextIsolation: true,
        preload: path.join(__dirname, 'preload.js')
      }
    })
  }
  
  // 窗口管理
  showWindow(): void { this.window.show() }
  hideWindow(): void { this.window.hide() }
  closeWindow(): void { this.window.close() }
  
  // 文件对话框
  openFileDialog(): string | null {
    return dialog.showOpenDialogSync(this.window, {
      properties: ['openFile']
    })?.[0] ?? null
  }
  
  // 系统通知
  showNotification(title: string, body: string): void {
    new Notification({ title, body }).show()
  }
  
  // IPC 通信
  sendIPC(channel: string, data: any): void {
    this.ipc.send(channel, data)
  }
}
```

### 2. CLI 外壳

```typescript
// src/Presentation/CLI/Shell.ts
export class CLIShell implements Shell {
  private readline: readline.Interface
  
  constructor() {
    this.readline = readline.createInterface({
      input: process.stdin,
      output: process.stdout
    })
  }
  
  // 终端输入
  async prompt(message: string): Promise<string> {
    return new Promise((resolve) => {
      this.readline.question(message, resolve)
    })
  }
  
  // 终端输出
  print(message: string): void {
    console.log(message)
  }
  
  // 文件对话框 (CLI 版本)
  openFileDialog(): string | null {
    // 使用 inquirer 或类似库
    return null
  }
  
  // 系统通知 (CLI 版本)
  showNotification(title: string, body: string): void {
    console.log(`[${title}] ${body}`)
  }
}
```

### 3. Web 外壳

```typescript
// src/Presentation/Web/Shell.ts
export class WebShell implements Shell {
  private ws: WebSocket
  
  constructor() {
    this.ws = new WebSocket('ws://localhost:3000')
  }
  
  // 窗口管理 (浏览器)
  showWindow(): void { /* 浏览器自动管理 */ }
  hideWindow(): void { /* 浏览器自动管理 */ }
  closeWindow(): void { window.close() }
  
  // 文件对话框 (浏览器版本)
  openFileDialog(): string | null {
    // 使用 <input type="file">
    return null
  }
  
  // 系统通知 (浏览器版本)
  showNotification(title: string, body: string): void {
    new Notification(title, { body })
  }
}
```

## 共享前端组件

### 1. Chat 组件

```typescript
// src/Shared/Chat/ChatView.tsx
export function ChatView({ shell }: { shell: Shell }) {
  const [messages, setMessages] = useState<Message[]>([])
  
  const sendMessage = async (text: string) => {
    // 通过 shell 适配层发送消息
    const response = await shell.sendHTTP('/api/chat', { text })
    setMessages(prev => [...prev, response])
  }
  
  return (
    <div>
      {messages.map((msg, i) => (
        <MessageBubble key={i} message={msg} />
      ))}
      <InputBox onSend={sendMessage} />
    </div>
  )
}
```

### 2. Session 组件

```typescript
// src/Shared/Session/SessionList.tsx
export function SessionList({ shell }: { shell: Shell }) {
  const [sessions, setSessions] = useState<Session[]>([])
  
  useEffect(() => {
    shell.sendHTTP('/api/sessions').then(setSessions)
  }, [])
  
  return (
    <div>
      {sessions.map(session => (
        <SessionItem key={session.id} session={session} />
      ))}
    </div>
  )
}
```

## 通信协议

### 1. HTTP Loopback

```typescript
// src/Shared/Communication/HTTPClient.ts
export class HTTPClient {
  private baseUrl: string
  
  constructor(port: number) {
    this.baseUrl = `http://localhost:${port}`
  }
  
  async get(path: string): Promise<any> {
    const response = await fetch(`${this.baseUrl}${path}`)
    return response.json()
  }
  
  async post(path: string, data: any): Promise<any> {
    const response = await fetch(`${this.baseUrl}${path}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(data)
    })
    return response.json()
  }
}
```

### 2. SSE 事件流

```typescript
// src/Shared/Communication/SSEClient.ts
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

## 构建与发布

### 1. 构建配置

```json
{
  "scripts": {
    "build:shared": "tsc -p tsconfig.shared.json",
    "build:electron": "electron-builder",
    "build:cli": "tsc -p tsconfig.cli.json",
    "build:web": "webpack --config webpack.web.js"
  }
}
```

### 2. 发布线

```
gh-harness/
├── dist/
│   ├── electron/          # Electron 桌面应用
│   │   ├── win32/         # Windows
│   │   ├── darwin/        # macOS
│   │   └── linux/         # Linux
│   ├── cli/               # CLI 应用
│   │   ├── win32/
│   │   ├── darwin/
│   │   └── linux/
│   └── web/               # Web 应用
└── packages/
    ├── shared/            # 共享前端代码
    ├── electron-shell/    # Electron 外壳
    ├── cli-shell/         # CLI 外壳
    └── web-shell/         # Web 外壳
```

## 优势

1. **代码共享**: 90%+ 前端代码在三种外壳间共享
2. **统一用户体验**: 相同的界面和交互逻辑
3. **独立发布**: 每种外壳可独立发布和更新
4. **平台优化**: 每种外壳可针对平台优化
5. **易于维护**: 修改一处，三种外壳同步更新

## 总结

通过**内核-外壳分离**和**共享前端层**，gh-harness 可以实现：
- CLI 和桌面共享同一份代码
- 统一的用户体验
- 独立的发布线
- 平台特定的优化

这正是 DeepSeek-Reasonix 的核心优势之一。