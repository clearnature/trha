# Reasonix CLI/TUI 架构分析 → trha 移植基线

**日期**: 2026-09-04（北京时间）
**对象**: `/home/yanli/work/DeepSeek-Reasonix-studio-v2.11.0` → trha Haskell CLI/TUI
**目的**: 提炼 Reasonix 的 IDE 基本功能面，映射到 trha 的插件化架构，作为移植与 TDD 开发的基线。

---

## 1. 拓扑扫描结论

### 1.1 Reasonix 相关代码面

| 区域 | 内容 | 与 trha 关系 |
|---|---|---|
| `internal/cli/`（~200+ 文件） | 主 CLI/TUI：`chat_tui.go`（bubbletea 状态机）、`plan_decision.go`、`toolcard.go`、`transcript.go`、`quick_picker.go`、`theme.go`、`status_footer.go`、`diffview.go`、`subagent.go`、`review.go`、`rewind.go`、`resume.go`、`model_view.go`、`slash_registry.go`、`completion.go` | **功能面主要来源** |
| `internal/control/` | 内核控制面：plan 状态机、`approval.go`（ask/审批队列、回合屏障）、`admission_guard.go`、checkpoint、branches | 依赖内核能力，trha 需扩展或骨架化 |
| `internal/event/` + `eventwire` | 事件模型（含 `ShellExecution`、`CacheDiagnostics`） | trha 事件总线（`Core.Event`）需对齐事件面 |
| `internal/serve/`、`internal/hook/`、`internal/store/` | HTTP 服务面 / 钩子 / 会话存储 | 接入协议来源 |
| `desktop/`（Electron + frontend-next React） | 桌面外壳 | 三端规划中的桌面/Web 参照 |
| `cmd/reasonix` | CLI 入口（flag 解析、命令树） | trha `Main.hs` optparse 参照 |

### 1.2 关键实现形态

- Reasonix TUI 是 **bubbletea（ELM 式）**；trha 用 **brick**（同为 ELM 式消息/状态机）→ **架构同构**，移植按"功能面 + 消息/状态设计"进行，不照搬 Go 代码。
- 渲染层高度组件化：toolcard / plan card / quick picker / status footer / transcript block 均为独立纯函数渲染单元 → trha 侧对应 brick Widget 组件。

---

## 2. IDE 基本功能面（用户可见能力矩阵）

按 Reasonix 拆为 10 个能力面，标注 trha 现状与依赖层：

| # | 能力面（Reasonix 文件） | trha 现状 | 依赖层 |
|---|---|---|---|
| F1 消息呈现 | `transcript.go`（markdown/代码块/工具卡/回放）、`toolcard.go`（工具状态/退出码/耗时）、`diffview.go` | 纯文本 strWrap；tool 仅一行文本 | **L0** |
| F2 输入编辑 | `composer_selection.go`、`composer_word_motion.go`、`chat_tui_paste.go` | 单行 editor | **L0** |
| F3 命令系统 | `slash_registry.go`、`quick_picker.go`、`complete.go`、`help_view.go` | REPL tab 补全；TUI 无 picker | **L0** |
| F4 状态/遥测 | `status_footer.go`（model/cache/usage/cost/context window）、`theme.go`、`output_style_view.go` | 状态栏含 model/session/usage；无主题系统 | **L0** |
| F5 会话控制 | `resume.go`、`rewind.go`、`transcript.go`、`checkpoint`、`compaction_card.go` | 会话在服务端；本地 transcript 已做；无 resume/rewind/compact UI | L0（协议）+L1 |
| F6 计划与审批 | `plan_decision.go`、`control/approval.go`、`ask_queue` | 无 plan/ask 状态机 | **L1**（内核+协议） |
| F7 模型/provider | `model_view.go`、`preset.go`、`provider.go` | `/models` 列表 + `/model` 切换；无详情视图 | L0+L1 |
| F8 子代理/任务 | `subagent.go`、`task_machine.go`、`todopanel`、`goaleval` | ~~trha-orchestration Subagent 骨架~~ ⚠️ **该库已于 2026-09-13 归档出构建**（`archive/orchestration/`），本行是当时的对照记录；TUI 无视图 | L1/L2 |
| F9 召回/记忆 | `memory.go`、`retrieval/`（BM25）、`historycatalog` | 无 | L2 |
| F10 扩展面 | `plugin.go`、`skill_*`、`mcp_*` | trha 插件系统（Core.Plugin）尚未被 CLI 使用 | L1（插件挂载） |

**依赖层定义**：
- **L0 纯外壳**：只消费现有内核协议（`/api/sessions/*`、`/v1/models`、StreamChunk）即可实现
- **L1 需内核扩展**：trha-core/API.Server 需新增状态/事件/端点（plan、approval、checkpoint、tool 事件详情、session 持久化恢复）
- **L2 深度能力**：检索/记忆/MCP/子代理进程隔离，依赖 trha 内核大规模能力建设

---

## 3. 架构契合点与移植原则

1. **同构移植**：Reasonix bubbletea 消息/状态设计 → trha brick `EventM`/`AppState`；组件渲染（card/footer/picker）→ brick `Widget` 组合；不搬运 Go 实现细节。
2. **插件化挂载**（deepseek-harness 思路）：每个能力面注册为插件——`Core.Plugin` 提供 `RegisterService/SubscribeEvent/ProvideEffect`；CLI/TUI 作为外壳通过**事件总线**消费内核事件（现状：HTTP 轮询/单请求；演进：事件流化）。
3. **协议优先、方法可移植**：Reasonix 外壳-内核协议（HTTP Loopback + SSE 事件流 + plan-decision 回合屏障）先在 trha 以 servant 端点落地，再让 TUI 消费——UI 与内核通过协议解耦，桌面/Web 三端共享同一协议面。
4. **先 CLI/TUI，后桌面/Web**：共享协议与共享渲染语义（消息块/卡片/状态行）抽象为共享库，桌面/Web 复用。

---

## 4. 已知差距基线（供 TDD 第一轮使用）

当前 trha CLI/TUI 已具备：CLI REPL（haskeline + slash 补全 + 历史）、brick TUI（流式累积渲染 PendingMsg、会话/模型 slash、usage 状态栏）、`settings.yaml` 分层配置（0700/0600/原子写）、本地 transcript（jsonl）。

待补第一梯队（建议 F1+F3+F4 的 L0 子集）：
1. **渲染组件**：assistant 消息 Markdown 子集（粗体/行内码/代码块带边框）、tool 调用卡（名称/参数/状态）
2. **quick picker**（/命令模糊选择面板，对照 `quick_picker.go`）
3. **状态页脚组件化**与主题抽象（对照 `theme.go`/`status_footer.go`：model/session/context/usage 分节）
