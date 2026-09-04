# DeepSeek-Reasonix Studio v2.11.0 架构分析

## 核心洞察

Reasonix 的架构设计体现了**内核-外壳分离**的精髓，实现了：
- **CLI 和桌面共享代码**：同一份前端，两种外壳
- **高性能与统一性**：Go 内核 + Electron/Wails 外壳
- **跨平台兼容性**：三平台统一发布线

## 架构分层

```
┌─────────────────────────────────────────────────────────────┐
│                    外壳层 (Shell Layer)                      │
│   ┌──────────────┐  ┌──────────────┐  ┌──────────────┐     │
│   │   Electron   │  │    Wails     │  │    CLI       │     │
│   │   Desktop    │  │   Desktop    │  │   (Terminal) │     │
│   └──────┬───────┘  └──────┬───────┘  └──────┬───────┘     │
│          │                 │                 │              │
│          └─────────────────┼─────────────────┘              │
│                            │ HTTP/IPC                       │
├────────────────────────────┼────────────────────────────────┤
│                    内核层 (Kernel Layer)                     │
│   ┌────────────────────────┴────────────────────────────┐   │
│   │                    Go 内核                           │   │
│   │  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐  │   │
│   │  │  Agent  │ │ Session │ │  Tool   │ │  Plan   │  │   │
│   │  │  Loop   │ │  Log    │ │ System  │ │ Lifecycle│  │   │
│   │  └─────────┘ └─────────┘ └─────────┘ └─────────┘  │   │
│   │  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐  │   │
│   │  │  Cache  │ │ Sandbox │ │  Update │ │ Telemetry│  │   │
│   │  │ Engine  │ │ Manager │ │   Hub   │ │         │  │   │
│   │  └─────────┘ └─────────┘ └─────────┘ └─────────┘  │   │
│   └────────────────────────────────────────────────────┘   │
├─────────────────────────────────────────────────────────────┤
│                    传输层 (Transport Layer)                  │
│   ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐        │
│   │  HTTP   │ │  SSE    │ │  IPC    │ │  gRPC   │        │
│   │ Loopback│ │ Events  │ │ (Electron)│ │        │        │
│   └─────────┘ └─────────┘ └─────────┘ └─────────┘        │
└─────────────────────────────────────────────────────────────┘
```

## 关键设计决策

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

## 核心模块分析

### 1. Plan 生命周期

```go
type State struct {
    Phase PlanPhase
    Epoch uint64  // 授权世代
}

type PlanPhase int
const (
    PlanIdle PlanPhase = iota
    PlanActive
    PlanAwaitingApproval
    PlanCompleted
)
```

**关键特性**:
- 带授权世代的宿主态
- ask 成为回合屏障
- 宿主拥有的决定成为投影

### 2. 沙箱安全

**两轴分离**:
- **Network**: 外网访问
- **HostAuthorities**: 宿主授权 (ssh_agent, docker, podman)

**凭据文件保护**:
- ~/.ssh/id_ed25519
- ~/.aws/credentials
- ~/.netrc
- ~/.git-credentials
- ~/.pypirc
- gcloud ADC

### 3. 上下文维护

**双重触发**:
- 窗口的 compact_ratio
- 可见输入的 context_soft_limit_tokens (默认 160000)

**召回检索**:
- BM25 原语
- 1k 条已折叠消息 2.3ms
- 5k 条 11ms
- 20k 条 44ms

### 4. 子代理系统

**审计通路**:
- SubagentHandoffSink
- 完成报告得到裁决而非一个词
- 只读子代理按写者方式汇报

## 对 trha 的启示

### 1. 内核-外壳分离

trha 应该：
- **核心引擎** (Haskell): 所有业务逻辑
- **外壳** (Electron/CLI): 用户交互

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

### 4. 安全模型

trha 应该：
- 实现两轴安全模型 (Network + HostAuthorities)
- 保护凭据文件
- 实现沙箱隔离

## 实施建议

### Phase 1: 核心引擎 (Haskell)
- 实现内核-外壳分离架构
- 实现 HTTP Loopback 通信
- 实现基础安全模型

### Phase 2: 外壳层 (Electron/CLI)
- 实现 Electron 外壳
- 实现 CLI 外壳
- 实现共享前端

### Phase 3: 高级特性
- 实现 Plan 生命周期
- 实现沙箱安全
- 实现上下文维护

### Phase 4: 发布线
- 实现三平台打包
- 实现自更新
- 实现签名与公证

## 总结

Reasonix 的架构展示了如何通过**内核-外壳分离**实现：
1. **代码共享**: CLI 和桌面共享同一份前端
2. **高性能**: Go 内核 + 类型安全
3. **统一性**: 统一的通信协议和发布线
4. **安全性**: 两轴安全模型和凭据保护

trha 应该借鉴这些设计，实现一个**类型驱动、可热插拔、极致并行**的下一代 AI 代理系统。