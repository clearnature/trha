# trha CLI/TUI 移植实施计划（对照 Reasonix IDE 基本功能）

**基线**: docs/reference/reasonix-cli-tui-architecture-analysis.md
**方法**: 架构分析 → 移植计划 → TDD（红→绿→重构）→ 沙盒验证；每阶段有可验证验收标准。
**范围**: 三端（cli/桌面/web）共享内核协议；本计划先做 CLI + TUI（L0 → L1），桌面/Web 后续复用协议与渲染语义。

---

## 1. 多路径推演（策略选型）

### 路径 A — 外壳先行（UX 横向铺开）
先做 L0 全部能力面（渲染组件、composer、picker、状态页脚、主题），不动内核。
- 复杂度：中低；性能：无关；可维护性：高（纯 UI）
- 风险：L0 之后必须等待 L1 内核扩展，中间无可交付纵深价值
- **评价**：作为第一阶段完全合适——立刻改善可用性、建立渲染组件库（三端复用语义）

### 路径 B — 内核协议先行
先扩展内核（plan/approval/tool 事件详情/会话恢复端点），再造 UI。
- 复杂度：高（跨层）；风险：内核改动大、UI 面长期无改善
- **评价**：不适合当前阶段；L1 应以**垂直切片**方式在 L0 组件成熟后逐个打穿

### 路径 C — 垂直切片（端到端单个能力）
取"计划 → 审批 → 工具执行可视化 → transcript"用户旅程，从内核到 TUI 一次打通。
- 复杂度：高；价值：纵深完整；风险：一次跨太多层，TDD 依赖面大
- **评价**：作为 L1 的组织方式（每切片带协议 + 内核状态机 + UI + 测试）

### 结论
**两段式**：Phase 1 用路径 A（L0 横向，TDD 快速收益）；Phase 2 用路径 C 的切片式（L1：plan/approval 切片 → tool 事件切片 → resume/compact 切片）。插件化挂载伴随 Phase 2 落地。

---

## 2. 分阶段路线（每阶段：范围 + 验收）

### Phase 1 — L0 外壳能力（纯 UI/UX，TDD）

| 步骤 | 功能 | 验收标准（TDD） |
|---|---|---|
| P1.1 | **Markdown 渲染组件**（粗体/行内码/代码块边框）：`UI/Render/Markdown.hs` 解析+渲染，纯函数 | hspec：三种语法解析/渲染 golden；中文宽度不断行 |
| P1.2 | **Tool 调用卡**（名称/参数/状态/退出码占位）：`UI/Render/ToolCard.hs` | hspec：卡片结构/多行参数/状态着色映射 |
| P1.3 | **Quick Picker**（/ 命令模糊过滤 + 方向键选择）：对照 `quick_picker.go` | hspec：过滤/高亮/窗口裁剪；brick 集成后手工冒烟 |
| P1.4 | **消息区组件化重构**：PendingMsg/消息/卡片统一为 widget 列表，保留流式累积 | 现有 TUI 冒烟 + /help 内容更新 |
| P1.5 | **状态页脚 + 主题抽象**：`UI/Theme.hs`（对照 theme.go 的 palette/style 结构），页脚分节（model/session/context/usage） | hspec：主题解析/回退默认；页脚组件 golden |
| P1.6 | REPL 与 TUI 共用命令注册表（对照 slash_registry） | hspec：命令解析/补全候选一致 |

Phase 1 完成 = 上述 hspec 全绿 + `cabal test` + TUI 人工冒烟清单。

### Phase 2 — L1 垂直切片（内核 + 协议 + UI，TDD）

| 切片 | 内容 | 验收 |
|---|---|---|
| S1 plan/approval | trha-core 增加 Plan 状态机（Idle/Active/AwaitingApproval/Completed，参考 control/approval + plancontract）；servant 增加 ask/plan-decision 端点（回合屏障）；TUI 出现 plan card（approve/deny 键） | 内核属性测试（状态非法迁移拒绝）；协议集成测试；TUI 冒烟 |
| S2 tool 事件详情 | StreamChunk/事件模型增加执行状态/退出码/耗时（对齐 `ShellExecution` 语义子集）；ToolCard 展示；transcript 记录 | JSON 编解码测试；transcript golden |
| S3 session 恢复 | 服务端会话持久化 + 恢复端点；CLI `resume` picker（本地 transcript 索引 + 服务端列表） | 持久化往返测试；resume 冒烟 |

### Phase 3 — 插件化挂载 + 三端协议共享
- CLI/TUI 能力以插件注册（`Core.Plugin`：命令集、渲染器、事件订阅），事件总线统一（HTTP/SSE 事件流或进程内）
- 共享渲染语义抽象成库（Haskell 侧 `trha-ui`），桌面/Web 复用协议与消息块结构
- 交付：三端共享协议文档 + 桌面/Web 起跑基线

---

## 3. TDD 工作约定

1. 每个 P/S 步骤先写 hspec 测试（红）→ 最小实现（绿）→ 重构
2. 纯函数渲染层与 IO/EventM 分离，保证可测性
3. 冒烟验证分两级：单元（hspec）+ 集成（真实服务端可跑时人工/脚本验证）
4. 防虚假完成：每步交付必须附测试输出与文件变更证据

### Phase 3 进展与路线注记（2026-09-05）
已完成：
- P3-0 三端共享协议总账 docs/contracts/protocol-shell-kernel.md
- P3-1 编排层 PluginManager 接入运行时（ServerConfig.plugins、钩子 session/message/tool、GET /api/plugins）
- P3-2/3 契约测试（plugins-runtime：init/create/message/tool/delete 全钩子）
- P3-4/5 动态宣告型插件管理（POST/DELETE /api/plugins；409/404 语义）+ vitest

后续深化建议（另起会话）：
- ~~C1 插件 ctx/effect 重构~~ ✅（2026-09-05）：PluginContext + activate(ctx)/deactivate + ctx.on 可逆订阅（unregister 先释放订阅再 deactivate，legacy 钩子兼容保留）；PluginManager 注入 Server EventBus。vitest plugins-context 57/57。
- ~~A1 插件目录加载器~~ ✅（2026-09-05）：src/Plugins/loader.ts（扫 *.js/*.mjs，default-export Plugin，坏文件跳过+告警）；ServerConfig.pluginsDir 启动注册。vitest plugins-loader 59/59。
- A1 本地插件目录加载器（pluginsDir 动态 import .js）——函数插件热加载载体；与 C1 配合。
- 外壳侧 /api/plugins 视图（/plugins 命令列已装插件）——小。
- 内核深化（真实工具执行、agent 内 ask）是插件可挂载内容的真正来源（Phase 3 后置）。

## 4. 备注

- 深度能力（F9 召回/BM25、F10 MCP、子代理隔离）不进入本轮 CLI/TUI 完善范围，保留为 trha 内核远期路线
- 桌面/Web 端仅保持"规划"状态（见 docs/ 既有设计），待 Phase 3 协议定型后启动
