# DeepSeek-Reasonix CLI 和桌面共享代码分析

## 核心洞察

DeepSeek-Reasonix 实现了 **CLI 和桌面共享代码** 的架构，这是其核心优势之一。

## 架构分析

### 1. 内核-外壳分离

**内核** (Go):
- 所有业务逻辑
- 会话管理
- 工具执行
- 计划生命周期
- 缓存引擎

**外壳** (Electron/Wails/CLI):
- 窗口管理
- 菜单系统
- 系统托盘
- 文件对话框
- 通知

### 2. 通信协议

```
外壳 ←→ 内核
│
├─ HTTP Loopback (localhost:port)
│  ├─ 认证: Cookie (非 query token)
│  ├─ CORS: 严格 origin 检查
│  └─ 端点: /api/*, /studio/*, /plan-decision
│
├─ SSE (Server-Sent Events)
│  ├─ 实时事件流
│  └─ 状态同步
│
└─ IPC (仅 Electron)
   ├─ 主进程 ↔ 渲染进程
   └─ 安全沙箱
```

### 3. 跨平台发布线

**Windows**:
- 安装器 (按用户安装)
- 便携版
- Authenticode 签名
- 自更新 (两步打包)

**macOS**:
- .app bundle
- 公证与钉封
- 自更新 (三方所有者)

**Linux**:
- .deb 包
- polkit 策略
- 自更新 (dpkg 升级)

## 关键设计决策

### 1. 外壳无关性

```go
// 内核不关心外壳类型
type Kernel struct {
    // 所有业务逻辑
}

// 外壳适配层
type Shell interface {
    ShowWindow()
    HideWindow()
    CloseWindow()
    OpenFileDialog() string
    ShowNotification(title, body string)
}
```

### 2. 统一前端

```typescript
// 前端代码不关心外壳类型
export class ChatView {
    constructor(private shell: Shell) {}
    
    async sendMessage(text: string) {
        // 通过 shell 适配层发送消息
        const response = await this.shell.sendHTTP('/api/chat', { text })
        // 渲染响应
    }
}
```

### 3. 平台特定优化

```typescript
// Electron 外壳
export class ElectronShell implements Shell {
    openFileDialog(): string {
        return dialog.showOpenDialogSync(this.window, {
            properties: ['openFile']
        })?.[0] ?? null
    }
}

// CLI 外壳
export class CLIShell implements Shell {
    openFileDialog(): string {
        // 使用 inquirer 或类似库
        return null
    }
}
```

## 对 trha 的启示

### 1. 架构分层

trha 应该：
- **核心引擎** (Haskell): 所有业务逻辑
- **外壳** (Electron/CLI): 用户交互
- **共享前端** (TypeScript): 90%+ 代码共享

### 2. 通信协议

trha 应该：
- 使用 HTTP Loopback 而非进程内调用
- 实现严格的 origin 检查
- 使用 Cookie 认证而非 query token

### 3. 跨平台发布

trha 应该：
- 实现统一的发布线
- 支持三平台自更新
- 实现签名与公证

## 实施建议

### Phase 1: 核心引擎 (Haskell)
- 实现内核-外壳分离架构
- 实现 HTTP Loopback 通信
- 实现基础安全模型

### Phase 2: 共享前端 (TypeScript)
- 实现 Shell 接口
- 实现共享组件
- 实现通信层

### Phase 3: 外壳层 (Electron/CLI)
- 实现 Electron 外壳
- 实现 CLI 外壳
- 实现平台特定优化

### Phase 4: 发布线
- 实现三平台打包
- 实现自更新
- 实现签名与公证

## 总结

DeepSeek-Reasonix 通过**内核-外壳分离**和**共享前端层**，实现了：
1. **代码共享**: CLI 和桌面共享同一份前端
2. **高性能**: Go 内核 + 类型安全
3. **统一性**: 统一的通信协议和发布线
4. **安全性**: 两轴安全模型和凭据保护

trha 应该借鉴这些设计，实现一个**类型驱动、可热插拔、极致并行**的下一代 AI 代理系统。