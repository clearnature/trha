# MiMo-Code TUI 完整形态分析（移植输入）

> 2026-10-25 · 五路并行研究员源码直读合成（组件形态 / 渲染框架 / 交互状态机 / 数据流 / trha 现状对比）。
> 对象：`/data/training/cli/MiMo-Code`（opencode fork，`@mimo-ai/cli`）。TUI 代码：`packages/cli/src/cli/cmd/tui/`（203 文件）。
> 本文档是 [`../plans/tui-port-plan.md`](../plans/tui-port-plan.md) 的事实输入。

## 0. BLUF

MiMo-Code 的 TUI 是一个**响应式、组件化、对话框/路由双层覆盖**的现代终端 UI：
SolidJS 细粒度响应式 + Zig 原生渲染器（yoga flexbox、truecolor、60fps 帧循环），
数据面是「事件总线 → 16ms 合并批处理 → 细粒度 store → 组件自动重绘」的流式管线。
形态面约 40+ 组件：Home/Session 双路由、13 种 Part 消息模型、按工具特化的渲染与 diff 审批、
extmark 虚拟文本编辑器、对话框栈 + 命令面板 + leader 键、Sidebar 插件槽、17 语言 i18n、32 主题。
trha 现有 TUI（brick，1360 行单文件）在其对照下的硬伤：**流式管线是空架子（SSE text delta 被丢弃）**、
无对话框系统、无 diff 审批、无多行输入、markdown 仅段落+代码块。移植的是**形态与交互契约**，不是代码（TS/Solid → Haskell/brick）。

## 1. 技术栈与架构分层

| 层 | MiMo-Code 实现 |
| --- | --- |
| 渲染器 | `@opentui/core@0.1.101`：Zig 原生库经 Bun FFI 加载，yoga-layout flexbox，FPS 上限帧循环（普通 60fps；plain terminal 降 10/15fps），truecolor `RGBA`、tree-sitter 语法高亮、可选 WebGPU |
| 绑定 | `@opentui/solid`：SolidJS 组件绑定，JSX intrinsic `<box> <text> <scrollbox> <textarea> <markdown> <code> <spinner> <diff>`，hooks `useKeyboard/useTerminalDimensions` |
| 进程模型 | TUI 线程 + Worker（后端）同进程双线程：`Rpc.client(worker)` JSON RPC；默认不走 TCP（worker 内 Hono `app.fetch` 直调），事件 `GlobalBus → Rpc "global.event" → TUI`；`--port` 时才走真 HTTP + SSE（断线指数退避 1s→30s） |
| Provider 嵌套 | Args→Exit→KV→Language→Toast→Route→TuiConfig→SDK→Project→Sync→Theme→Local→Keybind→PromptStash→Dialog→Command→Frecency→PromptHistory→PromptRef→App（`app.tsx:176-231`） |

## 2. 布局与视觉

- **Session 页**（`routes/session/index.tsx:1353-1554`）：水平 row = 主列（flexGrow 1）+ 可选 Sidebar（宽 42 列，`width>120` 停靠否则 absolute 半透明覆盖）；主列纵向 = 消息 scrollbox（`stickyScroll stickyStart="bottom"`）+ 输入区（textarea minHeight 1 / maxHeight 6）+ footer 两行。
- **主题**：JSON（`defs` + `theme` token + `{dark,light}` 双模式），32 套内置 + 自定义目录 + 「system」从终端调色板程序化生成；truecolor 默认路径，`renderer.setBackgroundColor` 同步终端背景；thinking 内容用 alpha 0.6 的 subtle 变体。
- **消息模型**：Message（User/Assistant 判别联合）+ 13 种 Part（`text/reasoning/tool/step-start/step-finish/patch/retry/compaction/…`）；**工具结果内嵌于 ToolPart.state**（pending/running/completed/error），不是独立 Part。
- **滚动**：无应用层虚拟化——规模控制靠数据层（每 agent 桶 ≤100 条消息，超出裁最旧）；stickyScroll + 手动滚动检测（`_hasManualScroll`）、per-agent scrollTop 记忆、滚动条滚后 2.5s 自动隐藏。
- **流式渲染**：唯一节流点 = TUI 端 **16ms batch**（`context/sdk.tsx:42-74`）；`message.part.delta` 直接字符串追加进 store（`sync.tsx:703-719`），Solid 细粒度订阅只失效受影响组件；服务端逐 delta 发布不节流。

## 3. 交互模型

- **三个正交维度**：路由（Home/Session，reconcile 切换）× 覆盖层（dialog 栈，zIndex 3000 半透明遮罩）× 输入模式（normal/shell）。
- **escape 层级表**（优先级）：文字选区复制 → dialog 弹栈 → shell 模式退出 → 关联想 → 丢 ghost 预测 → 审批页 cancel/reject → **5 秒内双击 escape 才中断会话**。
- **键盘**：全量默认键表（`config/keybinds.ts:17-119`）+ 逐键可覆盖（逗号多绑定、`<leader>` 前缀、`none` 禁用）+ leader 态（ctrl+x，2s 超时，输入框变暗让渡焦点）；分发是多层 `useKeyboard` 链 + `defaultPrevented` 让位；**无 vim 模式**。
- **焦点**：对话框打开记录并 blur 原焦点，弹栈后 setTimeout(1) 递归确认存活再恢复；prompt 在 dialog 打开期间主动 blur。
- **命令面板**：`ctrl+p`；`CommandOption{title,value,description,category,keybind,slash,suggested}`，7 固定分类，约 45 条全局命令 + prompt/session/插件注册；fuzzysort 加权（title×2+keywords×2+拼音×1）；`ctrl+_` 类键位经 keybind 名解析。
- **编辑器**：extmark 虚拟文本表示 @文件/$agent//命令 与粘贴占位（大文本转 `@filename`，提交前内联展开）；三种补全 + frecency 排序 + `file.ts#L10-L20` 行号；历史 JSONL（50 条，光标在首/末行才翻页）；草稿两层（路由切换自动暂存 + 手动 stash JSONL）；shell 模式（`!` 前缀）；ghost 预测（idle 时 `session.predict`，Tab 接受）；ctrl+e 外部编辑器。

## 4. 功能形态面（inventory 摘要）

- **消息流**：TextPart（markdown streaming=true）、ReasoningPart（Thinking spinner→Thought 标题+时长，折叠）、用户气泡（左竖线）、错误卡片（rate-limit 区分）、结构化输出折叠、消息级 footer 元信息。
- **工具渲染**：InlineTool（单行）/BlockTool（可展开）基元；按工具特化（Bash 输出折叠、Edit/ApplyPatch 用 `<diff>` renderable、Write 高亮、Task 点击跳转子 agent 会话）；`GenericTool` 兜底；`shouldHideTool` 完成后可隐藏。
- **审批**：14 类权限工具；once/always（二次确认）/reject（可附拒绝原因）；审批 diff ctrl+f **Portal 全屏**；`bash_delete` 无 always 项；审批期间消息流 disabled。
- **对话框**：栈式（replace 语义 + refocus）；模型选择（Favorites/Recent/置顶分区/模糊搜索/收藏持久化 `model.json`）、会话列表、命令面板、主题、状态（LSP/MCP）、上下文限额、审批超时档、技能、MCP 开关、Timeline/fork、子 agent、Toast 通知。
- **Sidebar 插件槽**：42 列停靠面板，内容全走插件槽（`mode="single_winner"`）：Context（token/成本/TPS/占用%）、TODO、Task 树、goal、LSP/MCP 状态。
- **其它**：Home（logo 动画 + 最近会话 + tips）、导出/分享转写、恢复流（失败候选提示）、声音反馈、外部编辑器、17 locale i18n（懒加载，非英文保留英文关键词搜索）、KV 偏好持久化（kv.json 文件锁原子写）。

## 5. trha 现状差距（对照判定）

| 能力 | MiMo-Code | trha 现状 | 判定 |
| --- | --- | --- | --- |
| 流式输出 | 逐 delta→16ms batch→细粒度重绘 | **SSE text delta 被丢弃**（`Bridge/Scheduler.hs:204-208`），回复整段到达；管线空架子 | **硬伤，第一优先** |
| 多行输入 | textarea 1-6 行、extmark、补全 | 单行 brick editor | 缺失 |
| markdown | streaming markdown renderable | 仅段落+围栏代码块；bold/code 解析后丢弃样式 | 简陋 |
| 工具渲染 | Inline/Block+折叠+特化 | 静态文本卡片 | 简陋 |
| diff 审批 | `<diff>` renderable+全屏切换 | 无（审批=plan 卡片+斜杠命令） | 缺失 |
| 对话框系统 | 栈+遮罩+escape 层级 | 无；模型/会话列表打印进消息流 | 缺失 |
| 命令面板 | fuzzysort+拼音+分类+keybind | `/` quick-picker（有基础） | 有基础 |
| token/成本 | 每步 finish part+Sidebar 占用% | 仅上次回复 totalTokens | 简陋 |
| 会话管理 | 列表/切换/fork/timeline/recovery | 文本列表+resume 回放 | 简陋 |
| i18n / 主题 / 设置面板 | 17 locale / 32 主题 / 插件槽 | zh-en / 2 主题（仅前景色）/ **三页签设置面板（完成度最高的部分）** | 有基础 |
| 测试 | — | UI 纯模块全测、**Brick.hs 1360 行零测试** | 风险点 |

**trha 的已有优势**（移植时保留）：设置面板三页签、命令注册表单一来源（Registry→picker/补全/帮助派生）、纯视图模型+spec 的测试惯例、转写持久化与 resume 回放、Bridge 的 HTTP/SSE 骨架。

## 6. 移植映射原则（进入计划的依据）

1. **语言/框架不可移植**（SolidJS/opentui 无 Haskell 等价物）→ 移植单元是**交互契约与组件形态**：布局区域划分、键位语义（escape 层级表）、事件粒度（delta + 批处理）、组件清单。
2. **trha 事件面与 MiMo 对齐良好**：scheduler SSE 已有 tool/textDelta/message 分类（`Core/SSE.hs:80-88`），消息模型已有 ToolEvent/Usage/PlanView（`Core/Types.hs`）——数据面缺口是 CLI 侧消费，不是后端重写。
3. **brick 无 extmark/虚拟文本** → 补全占位、粘贴折叠需用自定义 widget 或降级为「提交时展开」简化版。
4. **单文件 Brick.hs（1360 行）必须先拆**（本仓重构惯例：每文件一职责、纯视图模型可测）——移植过程即拆分过程。

## 7. 交叉验证记录

16ms batch（数据流 lane `sdk.tsx:42-74` × 渲染 lane `sync.tsx:703-719` 印证）、dialog 栈语义（交互 lane `ui/dialog.tsx` × 组件 lane `Dialog*` 清单印证）、审批流（数据流 lane `permission/index.ts` × 组件 lane `permission.tsx` 印证）——关键声明均有 ≥2 条 lane 独立直读，VERIFIED。唯一 MED 项：opentui core 内部 culling 与 markdown streaming 实现（node_modules 未安装不可直读），对移植计划无决策影响。
