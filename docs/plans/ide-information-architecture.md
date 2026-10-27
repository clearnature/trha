# trha IDE 信息架构（IA）

> **日期**：2026-10-26 · **状态**：草案（待裁定，见 §11）· **性质**：产品形态定义，不是实施计划
> **依据**：两壳**实测代码**（TUI 已在 `packages/app/CLI/UI/`，Desktop 在 `packages/app/Desktop/src/renderer/`）
> + 四上游形态（MiMo-Code / qwen-code / reasonix / dsh）。
> **判据**：本文只描述"人在哪儿看什么、怎么在区域之间移动"，不描述实现。

---

## 0. 一句话

trha 的 IDE **不是**"给编辑器加一个 AI 侧栏"，而是**以会话为主视图的工作台**：
代码、差异、终端都是**从会话里的动作派生出来的从属视图**，不是一个可以独立漫游的文件世界。

这条判据决定了下文每个区域的存在理由——凡是不能追溯到某条会话事件的区域，都不该出现在首版 IA 里（见 §2 不变量 I1）。

---

## 1. 现状依据（实测，非构想）

| 面 | TUI（Haskell / brick） | Desktop（Electron / React） | 差距 |
|---|---|---|---|
| 主路由 | `RouteHome`（logo + 最近会话）/ `RouteSession`（消息流） | 单页：`MessageList` + `PlanPrompt` + `Composer` | Desktop 无 Home |
| 绘制层次 | `drawUI` = 对话框层 > 侧栏浮层 > 主层，设置全屏接管 | `Shell` 三区插槽（sidebar \| main \| statusBar）+ 设置全屏覆盖 | 层次模型不对齐 |
| 右侧工作台 | 十节 registry：Context / CWD / Files / Goal / Instructions / TODO / Agents / LSP / MCP / Session | **无** | **最大形态缺口** |
| 左侧导航 | 无（Home + 对话框承担） | 会话列表 + mode 选择 + tools/models 目录 | 两边语义不同 |
| 命令入口 | `/` 与 `ctrl+p` 内联 palette（30 行窗口，非居中模态） | 无 | 缺 |
| 对话框 | 11 种（models/sessions/commands/providers/presets/skills/agents/themes/languages/approval/confirm），栈式 LIFO + escape 层级表 | 无（设置面板内嵌） | 缺 |
| 审批/计划 | 计划卡片（步态 + 待决标记）+ 审批对话框（破坏性命令无 "always"） | `PlanPrompt` | 弱 |
| 工具卡 | 折叠/展开/聚焦/拖选/逐卡 fold 状态 | `ToolCard`（无折叠、无聚焦） | 弱 |
| 状态带 | 12 个可配置 metric（model/mode/cache/ctx/compact/session/git/workspace/tokens/usage/context/tps） | `StatusBar`（简单） | 弱 |
| 设置 | 全屏接管，按组排序 | 8 组 / 22 tab，带 done/partial/scaffold 徽标 | **Desktop 反而更完备** |
| 编辑器 | 无（`ctrl+e` 交外部 `$EDITOR`） | 无 | 都缺 |
| 差异视图 | `Render/Diff.hs`（工具卡内的 diff 配色） | 无 | 缺 |
| 终端 | shell 模式（`!` 前缀）单发命令 | 无 | 缺 |
| 依赖 | vty/brick | 仅 `react/zustand/axios/winston`——**无 monaco / codemirror / xterm / shiki** | 选型未定 |

**结论**：TUI 已经是成型的 **agent 工作台**；Desktop 落后一个形态代差，但其**设置面更完整**。
IA 的正确做法是**以 TUI 形态为基线统一区域模型**，把 Desktop 的设置中心吸纳进来，而不是给 Desktop 另起一套。

---

## 2. 三条不变量

| # | 不变量 | 含义 | 现状证据 |
|---|---|---|---|
| **I1** | **可追溯** | 任何非对话区域里显示的对象都必须锚定到一条会话事件：工具卡 → 它改的文件/差分；TODO 项 → 计划步；Agents 树节点 → 子会话 sid。无来源的区域不许存在 | TUI 侧栏的 `Files/Goal/Instructions` 全部来自 `GET /api/session/:id` |
| **I2** | **决策阻塞且不可预授权** | 审批只能从对话流升起；破坏性命令不提供 "always" | `UI/Dialog.hs` `isDestructiveShell` / `approvalOptions` |
| **I3** | **设置与工作区分层** | 设置中心是**全屏替换**，不是侧滑抽屉——改配置时不能误触会话 | TUI `drawUI` 中 `appSettings` 非空即整屏接管 |

---

## 3. 区域模型

### 3.1 宽屏（≥ 全景）

```
┌───────────────────────────────────────────────────────────────────────────┐
│ R1 Chrome   trha · workspace-name · main↑2 · mode:ask · DeepSeek/xxx        │
├──────┬────────────────┬──────────────────────────────┬────────────────────┤
│ R2   │ R3 Sessions    │ R4 Main surface              │ R5 Agent dock      │
│ Rail │                │                              │  Context           │
│ ○ ⌂  │ ▸ 会话标题 A   │  ┌ user ───────────────────┐ │  CWD               │
│ ○ ⧉  │ ▸ 会话标题 B ● │  │ ...                     │ │  Files             │
│ ○ ±  │ ▸ 会话标题 C   │  └─────────────────────────┘ │  Goal              │
│ ○ ⌸  │                │  ┌ assistant ──────────────┐ │  Instructions      │
│ ○ ▷  │                │  │ ...                     │ │  TODO              │
│ ○ ⚙  │                │  └─────────────────────────┘ │  Agents            │
│      │                │  ┌ tool: edit ▸ ───────────┐ │  LSP / MCP         │
│      │                │  │ src/Foo.hs +12 −3       │ │  Session           │
│      │                │  └─────────────────────────┘ │                    │
│      │                │  [ 计划卡片 / 审批卡片 ]     │                    │
│      │                ├──────────────────────────────┤                    │
│      │                │ R6 Composer                  │                    │
│      │                │ > _                          │                    │
│      │                │ [内联 palette / @ 补全]      │                    │
├──────┴────────────────┴──────────────────────────────┴────────────────────┤
│ R7 Status   model · mode · cache 92% · ctx 41% · compact 58% · git · tok   │
└───────────────────────────────────────────────────────────────────────────┘
```

### 3.2 窄屏（< 1100px）

侧栏与 dock 退为**浮层**（TUI 的 80 列规则：`UI/Layout.hs` 已实现停靠/浮层/隐藏三态，Desktop 应复用同一语义）：
R2 rail 收成图标条；R3 sessions 浮层；R5 dock 浮层。**R4 永远不被压缩到无法阅读**。

### 3.3 区域定义表

| ID | 区域 | 职责 | 数据源 | TUI | Desktop |
|---|---|---|---|---|---|
| **R1** | Chrome | 身份与全局状态：workspace、git 分支、权限姿态、provider/model | `/api/session/:id`、本地 git、`/api/providers` | 部分（footer + 侧栏） | 无 |
| **R2** | Rail | 产品级导航：会话 / 文件 / 变更 / 运行 / 设置 | — | 无 | 无 |
| **R3** | Sessions | 会话列表（新建/选择/删除/重命名/tag/fork） | `/api/sessions` | Home + `/sessions` 对话框 | `Sidebar.tsx` 会话列表 ✅ |
| **R4** | Main | 主工作区，承载 §5 的五个视图 | SSE + `/api/session/:id/messages` | `RouteSession` | 仅 V1 |
| **R5** | Agent dock | 情境感知：会话的"现在处于什么状态" | 见 §3.4 | ✅ 十节 | ❌ |
| **R6** | Composer | 输入 + palette + `@` 补全 + 附件 + 模式切换 + queue/steer | `/api/agent/step`、`/queue`、`/steer` | ✅ | 基础 |
| **R7** | Status | 可配置遥测带 | 同 `metricKeys` 目录 | ✅ 12 key | 弱 |

### 3.4 R5 的节注册表（**新增即一行，不改主绘制**）

沿用 TUI 的 `sidebarSections` 插件式注册（`UI/Render/Sidebar.hs`），顺序即显示顺序，每节自带空态：

| 节 | 内容 | 来源 |
|---|---|---|
| Context | in/out/total + ctx 占用 % | `Usage` + model ctxSize |
| CWD | 工作目录 | `GET /api/session/:id` |
| Files | 工作区文件抽样 | 同上（`@` 索引） |
| Goal | 会话目标 | `create_goal/get_goal` |
| Instructions | 检测到的 AGENTS.md / REASONIX.md | 同上 |
| TODO | 团队任务三态（○/◐/●） | team tasks |
| Agents | 子会话树（缩进、当前 ●、上限 8 行） | `/api/sessions` 的 `parentId` |
| LSP | 运行状态 / 诊断数 | `/api/lsp/status` |
| MCP | configured / connected | `/api/mcp/status` |
| Session | sid、标题、模型 | 本地 transcript + `/api/session/:id` |

> Desktop 落地时这十节应作为**一个 registry 模块**交付，而不是在 `Sidebar.tsx` 里堆十个 `if`。

---

## 4. 主视图与分屏策略

**主视图恒为 Conversation（V1）**。其余视图是**从属视图**，规则三条：

1. **有锚点才可打开**（I1）：只有对话里出现过"某个文件/某次改动/某个作业"时，对应视图才可进入。
2. **同一时刻最多一个从属视图**，与会话**并排**（宽屏）或**接管**（窄屏）。不做 VS Code 式的多面板叠加——那是"文件世界优先"的 IA，与本项目 §0 判据冲突。
3. **切换不丢上下文**：从属视图关闭后，主视图滚动位置与输入草稿保持（TUI 的 `Stash` 已解决草稿丢失）。

```
宽屏分屏：                             窄屏：接管
┌──────────────┬──────────────┐       ┌────────────────┐
│ V1 会话      │ V2 变更(diff)│       │ V2 变更        │
│              │              │  ⇄    │ [← 返回会话]   │
└──────────────┴──────────────┘       └────────────────┘
```

---

## 5. 视图清单

| ID | 视图 | 职责 | 进入方式 | 依赖分类 |
|---|---|---|---|---|
| **V1** | Conversation | 消息流（user / assistant / reasoning / tool card / 计划 / 审批 / notice） | 默认 | A（已有） |
| **V2** | Changes | 工作树差异：按文件分组、可折叠；点 hunk 跳到 V3 | 点工具卡的 patch 区；R2「变更」 | **B**：无 `/api/fs`、无 diff 端点 |
| **V3** | File | 文件内容（只读 + 语法高亮）；行号锚点 | 点 V2 的 hunk；dock「Files」 | **B**：无文件端点 |
| **V4** | Terminal | 人可见的终端会话（与 `terminal_*` 工具共用同一 pty） | `!` 前缀；R2「运行」 | **B**：`terminal_*` 工具已有，无人类入口 |
| **V5** | Run | 计划/子代理/后台作业的详情（步态、耗时、日志） | 点计划卡片；dock「Agents/TODO」 | A/B 混合 |

**分类沿用 `tui-port-plan.md` 的约定**：A = 纯外壳可做；B = 需先落 scheduler/内核端点（**不做空壳**）。

---

## 6. 覆盖层与键位层级

覆盖层不占区域，浮在 R4 之上；**关闭顺序固定**（TUI 的 `resolveEscape` 五级已定义，应升级为跨壳契约）：

```
选区 → 对话框栈 → shell 模式 → 补全弹层 → 审批（拒绝）
```

| 覆盖层 | 形态 | 说明 |
|---|---|---|
| O1 命令 palette | 内联于 Composer 上方（30 行窗口） | **不是**居中模态——MiMo 形态，输入时边打边过滤 |
| O2 对话框 | 居中卡片，栈式 LIFO | models / sessions / providers / skills / agents / themes / languages |
| O3 审批 | 阻塞卡片 | 破坏性命令无 "always"（I2） |
| O4 设置中心 | **全屏替换**（I3） | 见 §7 |
| O5 Toast | 主区上方条带 | 瞬时通知，不打断 |

**中断的二次确认**：运行中双击 esc 才中断（5s 窗口）——按钮式"停止"单独放在 R6 右侧，避免误触。

### 6.1 交互层（L0–L7）：代码里的真实分层

命令不是扁平清单，是**一棵交互状态树**。每一层只做一件事：**谁拥有键盘**。下表按 `UI/Brick.hs` 的实际路由顺序列出：

| 层 | 状态字段 | 键权归属 | 退出 | 备注 |
|---|---|---|---|---|
| **L0 会话输入** | — | `handleChatKey` | — | 底层，其余层都浮在它之上 |
| **L1 补全弹层** | `appComp` | 同上（优先于 L0） | Esc 关闭 | ↑/↓ 移动，Tab/Enter 插入 |
| **L2 命令 palette** | `appPalette :: Maybe Dialog` | 同上 | **Esc 只关列表，不清输入** | 内联于输入框上方，非居中模态 |
| **L3 leader** | `appLeader` | `handleLeaderKey` | 任意未绑定键即失效 | `ctrl+x` 布防，单键一次性 |
| **L4 对话框栈** | `appDialogs :: DialogStack` | `handleDialogKey` | Esc 弹栈 | **栈顶独占全部按键**，可继续 push（providers → presets） |
| **L4.5 向导** | `appWizard :: Maybe ProviderWizard` | 内联在 L4 分支里 | Esc 取消并**清空输入** | **不在栈里**，是 providers 对话框的私有子状态 |
| **L5 设置面板** | `appSettings :: Maybe SettingsPanel` | `handleSettingsKey` | Esc 由它自己解释 | 全屏接管；内部还有 tabs → 搜索 → 编辑 三种焦点 |
| **L6 终端交还** | — | `suspendAndResume` | 子进程退出 | `ctrl+e` 编辑器、shell 挂起 |
| **L7 异步回合** | `appBusy` + SSE | 仍归 L0 | 双击 Esc（5s） | **不是覆盖层，是模式**：期间输入可排队/插入 |

### 6.2 键权的三条规则

1. **单栈单主**：同一时刻只有最上面一层解释按键；下层不得"偷看"。
2. **Esc 只退一层**，且退的是**当前最上层**，不能跳层（palette 里的 Esc 不许把对话框关掉）。
3. **网络/阻塞不占键线程**：任何层都不能在事件线程上做超过一帧的 IO（见 §6.4 D3）。

### 6.3 命令 → 层的映射（这是"能不能用"的判据）

一条命令"能用"= 它进入了**正确的层**，并在该层完成后把结果写回**正确的状态**。当前代码只做了第一半：

| 层 | 应进入的命令 | 现状 |
|---|---|---|
| L0 纯回报（文本即可） | `/help` `/status` `/context` `/usage` `/stats` `/session-info` `/transcript` `/graph` `/goal` `/todo` `/tree` `/doctor` `/memory` `/remember` `/preset` `/hooks` `/mcp` `/lsp` `/attachments` `/clear-attachments` `/currency` `/ask-timeout` `/reasoning-language` `/output-style` `/copy` `/verbose` `/diff` `/cls` `/plugins` | ✅ 已按此实现（但 `/diff` 用进程 cwd，见 D6） |
| L4 对话框 / 选择器 | `/models` `/sessions` `/provider` `/skills` `/agents` `/theme` `/language` `/resume` `/delete`(confirm) `/stash`(list) | ✅ TUI 已接 |
| L4.5 向导 | `/provider` 内的 `a`/`e`（新增/编辑六步） | ✅ 已接，但**不在栈里**（D2） |
| L5 设置面板 | `/settings` | ✅ 已接（但 Esc 语义独立，D4） |
| L6 终端交还 | `/vim` · `ctrl+e` | ❌ **`/vim` 走 REPL 实现**（`Commands.hs:684` 用 `readProcessWithExitCode`，没有 `suspendAndResume`）→ 与 brick 抢终端，必然坏（D5） |
| L7 异步回合 | `/retry` `/btw` `/recap` `/compact` `/queue` `/steer` `/fork` `/branch` `/loop` `/workflow` | ❌ **10 条全部落到 `executeCommand` 同步执行**（D3） |
| L7-lite 状态写 | `/switch` `/rename` `/tag` `/mode` `/fav` | 🟡 rename/tag/mode 在 TUI 内有分支；`/switch` 只写配置不刷新 TUI 状态（D7） |
| 退出 | `/quit` `/exit` | ✅ |

### 6.4 已定位的层缺陷

| # | 缺陷 | 证据 | 后果 |
|---|---|---|---|
| **D1** | **两套 escape 模型并存且顺序不同**：纯模型 `UI/Dialog.resolveEscape` 是 `选区 → 栈 → shell → 补全 → 审批`；真实路由 `Brick.hs:1456-1470` 是 `设置 → 向导 → 补全 → palette → 选区/栈/…` | `Dialog.hs:resolveEscape` vs `Brick.hs:1456` | 纯模型测不出真实行为；新增层必然漏 |
| **D2** | 向导 `appWizard` 不在 `DialogStack` 里，Esc 语义与栈不同（还清空输入） | `Brick.hs:1460-1463` | 无法在向导上叠选择器；返回语义不一致 |
| **D3** | **10 条回合命令在 brick 事件线程上同步跑网络** | `Brick.hs:3127` `liftIO $ executeCommand …`；`Commands.hs:640/628/616` 直接 `retrySession/btwAsk/recapSession`；默认 `configTimeout = 120000`（`Core/Types.hs:532`） | 一条命令可让整个 TUI 冻结最长 120 秒——**这就是"命令无法使用"的直接原因** |
| **D4** | 设置面板的 Esc 不经过全局层级表 | `Brick.hs:1502` → `handleSettingsKey` | 层级规则对 L5 不成立 |
| **D5** | `/vim` 未使用 `suspendAndResume` | `Commands.hs:684`；对照 `Brick.hs:3702` 的 `ctrl+e` | 外部编辑器与 brick 抢终端 |
| **D6** | `/diff` 在**进程 cwd** 跑 git，而工作区以 `TRHA_WORKSPACE`/会话 cwd 为准 | `Commands.hs:359` | 从别处启动时永远显示 "No uncommitted changes" |
| **D7** | `/switch` 只改内核 in-use 与配置文件，不刷新 `appProvider`/模型 | `Commands.hs:538`（无 modelRef 参数，无 `EvProviders`） | footer/picker 仍显示旧 provider |
| **D8** | TUI 传入的 `modelRef` 从不读回 | `Brick.hs:3124-3131` 只同步 `sessionRef` | 任何写 modelRef 的命令都静默失效 |
| **D9** | `SkipStep/RejectStep/AbandonPlan` 各写了两遍方程 | `Commands.hs:856-858` 与 `984-986` | 后者不可达；`abandon` 的语义在两处不同（`"abandon"` vs `"reject"`） |

> **修法不是逐条打补丁**，而是把"层"变成数据：在纯注册表里给每条命令标注 `CommandLayer`，TUI 按层分派（L0 直接回报 / L4 开栈 / L4.5 进向导 / L5 开面板 / L6 交还终端 / L7 起异步并写回状态）。D1–D9 里除 D1、D2 是结构问题，其余都是这张表落地后自然消失的。

### 6.5 brick 3.0 提供什么、不提供什么

参考源码：`3rdparty/brick-3.0/`（version 3.0，vty 6.6）。**结论先说：brick 不提供层栈**，`KeyDispatcher` 是扁平的 key→handler 表，所以 `Layer` 必须是应用级概念——这正是 `UI/Interaction.hs` 存在的理由。

| brick 3.0 模块 | 能力 | 与本项目的关系 |
|---|---|---|
| `Brick.Main.customMain` + `mkVty` | 事件循环；`mkVty` 在 resume 时重建 vty | 已用（`Brick.hs:451-459`） |
| `Brick.Main.suspendAndResume` | 存终端状态 → 跑子进程 → 恢复 | `ctrl+e` 已用（`Brick.hs:3702`）；`/vim` 未用（D5） |
| `Brick.Keybindings`（`KeyDispatcher`/`KeyConfig`/`Parse`） | **扁平** dispatch 表 + 用户可配置绑定（INI）+ 冲突检测 | 表达不了层；适合做"绑定可配置"，层栈仍归 app |
| `Brick.Focus`（`FocusRing`） | 单维焦点环（next/prev/current） | 设置面板现在是手写 `SettingsFocus` 三态；可用 FocusRing 替换，但嵌套仍需组合 |
| `Brick.Forms` | 字段级状态机 + 校验 + `renderForm`/`handleFormFieldEvent` | **provider 六步向导的天然载体**（现在手写 `ProviderWizard`） |
| `Brick.BorderMap` | 屏幕坐标 → 值的映射 | **T1 的跳转锚点**（点工具卡 → 文件行、点 hunk → 行号）的正确工具 |
| `Brick.Widgets.FileBrowser` | 目录浏览 / 搜索 / 过滤 / 选择 | T1 的 V3 文件选择可复用；只读查看器仍需自建 |
| `Brick.Widgets.Dialog` | 按钮式模态（`dialog`/`renderDialog`/`handleDialogEvent`） | 比现有 `Dialog` 栈弱（无过滤列表、无多步、无向导），**不替换** |
| `Brick.Widgets.Table` / `MenuBar` / `ProgressBar` | 表格 / 菜单栏 / 进度条 | 未用；`Table` 可用于 T1 的变更列表 |

**一个未验证点（不要当结论用）**：TUI 用 `mkVty defaultConfig` 建 vty，而 brick 源码里**从不设置** `mouseEnabled`（`grep -rn mouseEnabled src/` 无命中）。vty 6.6 的 `defaultConfig.mouseEnabled` 究竟是 `True` 还是 `False`，本轮没有测得（本机 package db 里有两份 `vty-6.6`，`ghc -e` 报 ambiguous）。**在确认之前，不要把鼠标相关行为当已接线**；`/mouse` 那条命令又是直接往 stdout 写 ANSI 序列（`Commands.hs:258-264`），与 vty 自己的鼠标开关是两套机制——这两件事必须一起验。



---

## 7. 设置中心（工作区之外）

Desktop 的 8 组 / 22 tab（`state/settingsTypes.ts`）作为**唯一权威分类**，TUI 的设置页收敛到同一分类：

| 组 | tab | 与工作区的边界 |
|---|---|---|
| 偏好设置 | 通用、模型 | — |
| 模型 | 模型偏好、模型服务、用量统计 | 切换 provider/model 的**快捷入口**留在 R1/R3 |
| 集成与连接 | 机器人、MCP 与工具、远程 SSH | 连接**状态**在 dock（LSP/MCP 节），**配置**在设置 |
| 能力扩展 | Skills、子智能体、插件 | 同左 |
| 记忆与上下文 | 记忆 | — |
| 自动化与开发者 | Hooks、诊断 | `/doctor` 结果也进「诊断」 |
| 安全与控制 | 权限、沙箱、网络、浏览器控制 | **权限姿态**（read-only/ask/auto/yolo/plan）是高频项，必须同时留在 R1 与 Composer |
| 应用 | 外观、快捷键、存储与路径、关于 | 主题/语言改动即时生效 |

**判据**：一个配置项若"改了以后要立刻看到工作区变化"，则在工作区有一个**镜像入口**，但**唯一的写入点仍在设置**（避免两处写同一状态）。

---

## 8. 状态与遥测带（R7）

共用一份 key 目录（TUI 已实现 `metricKeys` + `parseMetrics`），两壳只消费不各自发明：

```
model · mode · cache · ctx · compact · session · git · workspace · tokens · usage · context · tps
```

默认展示：`model,mode,cache,ctx,compact,session`。
**空值不伪造**：provider 未上报缓存就显示空，不显示 0.00%（`Footer.hs` `rate` 的既有纪律）。

---

## 9. 与契约的映射

### 9.1 现有端点（够用）

| 区域/视图 | 端点 |
|---|---|
| R3 | `GET /api/sessions` · `POST /api/session/start` · `DELETE /api/session/:id` · `POST /api/session/:id/meta` |
| R4 消息 | `GET /api/session/:id/messages` · SSE `/api/events` · `POST /api/agent/step` |
| R4 决策 | `POST /api/session/:id/decision` · `/interrupt` · `/answer` · `/plan` |
| R5 | `GET /api/session/:id`（cwd/files/goal/instructions）· `/api/mcp/status` · `/api/lsp/status` · `/api/sessions`（agents 树） |
| R6 | `POST /api/agent/step` · `/queue` · `/steer` · `/compact` · `/btw` |
| R7 | `GET /api/usage-stats` · `/api/balance` · model ctxSize |

### 9.2 缺失端点（IDE 面的真实前置）

| 需要 | 端点（建议） | 阻塞视图 |
|---|---|---|
| 工作区文件树 | `GET /api/fs/tree?root&depth` | V3、dock Files 升级 |
| 文件内容（带行号） | `GET /api/fs/file?path&range` | V3 |
| 工作树差异 | `GET /api/fs/diff?session` | **V2（最关键的 IDE 面）** |
| 终端会话的人类入口 | 复用 `terminal_*`：`GET /api/terminal/:sid/stream` | V4 |

> **纪律**：这四项任一未落地，对应视图就不进 UI（`tui-port-plan.md` 的"不做空壳"）。

---

## 10. 差距矩阵与落地阶段

> **2026-10-26 裁定：TUI 先行**（见 §11 裁定记录）。阶段顺序按此重排——原"先补 Desktop"作废。

| 阶段 | 内容 | 依赖 | 判据 |
|---|---|---|---|
| **T0 TUI 收尾** | 按 `tui-port-plan.md` 的剩余原子：M5-7 file part · M6-7 `shouldHideTool` · M8-3 分类/拼音 · M9-1..M9-3（extmark / 大段粘贴折叠 / 补全 frecency+行号）· M10-5 鼠标选区 · M4-4 的设置内 Provider 页签 | A | `cabal test trha-cli-test` 全绿 + 新增 spec |
| **T1 TUI 的 IDE 面** | **V2 Changes**（会话内全屏差异视图）· V3 File（只读 + 高亮 + 行号锚点）· 工具卡 ↔ 文件行跳转 | **B**（§9.2 前三项） | 能从一张 `edit` 卡跳到它的 diff，再从 diff 跳到文件行 |
| **T2 两壳对齐** | Desktop 补齐 R5 dock · O1 palette · O2 对话框栈 · O3 审批 · R7 metrics · R1 Chrome | A（TUI 已实现，形态即规格） | Desktop 与 TUI 的 IA 同构 |
| **T3 共享渲染** | 抽出 `trha-ui`（plan-reconciliation G3） | — | 两壳不再各写一遍区域模型 |

**顺序理由**：
1. T0/T1 是**同一份代码**（Haskell CLI 包）上继续推进，无跨语言共享成本；且 TUI 的形态已被 383 例 spec 与 pty 实测锁定。
2. **T1 的 V2 Changes 是整个项目的形态分水岭**——"assistant 改了什么"是 agent IDE 与聊天客户端的唯一硬指标，TUI 先做到，Desktop 才有可抄的规格。
3. Desktop 的 R5/O1/O2 全部可以照抄 TUI 的纯视图模型（`SidebarData`、`DialogStack`、`FooterLive`），到 T2 时是搬运而不是设计。

**TUI 形态下 §5 视图的裁剪**（终端是宿主，不是面板）：

| 视图 | TUI 是否成立 | 说明 |
|---|---|---|
| V1 Conversation | ✅ | 主视图 |
| V2 Changes | ✅（T1） | 全屏接管 + 折叠；数据来自工具事件与 `/api/fs/diff` |
| V3 File | ✅（T1） | 只读 + 行号；编辑走 `ctrl+e` 外部 `$EDITOR`（M9-7 已落地） |
| V4 Terminal | ❌ 不适用 | 终端本身就是宿主；`!` shell 模式（M9-4）已覆盖"直接跑命令" |
| V5 Run | ✅ | 计划卡 / Agents 树已在 R5，详情页可后置 |

---

## 11. 裁定记录与待定

### 11.1 已裁定（2026-10-26）

| # | 问题 | 裁定 | 对本文的影响 |
|---|---|---|---|
| **Q1** | 主视图优先级 | **先完成 TUI 的开发** | §0 的"会话优先"判据不变；但落地顺序改为 §10 的 T0→T3，Desktop 的对齐后置 |
| **Q5** | 两壳关系 | **先完成 TUI 的开发**（Desktop 暂缓） | T2 才开始补 Desktop；T3 的 `trha-ui` 更靠后 |
| **Q2** | 真编辑器边界 | **被 Q1 连带确定**：TUI 侧"编辑"= `ctrl+e` 外部 `$EDITOR`（M9-7 已落地），不引入内置编辑器 | V3 在 TUI 中只读；Desktop 侧的问题留到 T2 再议 |

### 11.2 仍然待定

| # | 问题 | 选项 | 何时需要定 |
|---|---|---|---|
| **Q3** | 终端是否要人类可交互 | (a) 只读输出 (b) 全交互 pty | T2（Desktop V4）时才需要 |
| **Q4** | 工作区模型 | (a) 单工作区（当前 scheduler 语义）(b) 多工作区/多窗口 | T1 做 `/api/fs/*` 时顺带确定根节点语义 |
| **Q6** | Changes 视图的数据口径 | (a) 只用工具事件里携带的 patch（无新端点）(b) 新增 `/api/fs/diff` 看整个工作树 | **T1 开工前必须定**——(a) 只能看"本轮改了什么"，(b) 才能看"工作树现在脏在哪" |
| **Q7** | TUI 的 V3 File 是否需要语法高亮 | (a) 纯行号 + 等宽（brick 原生）(b) 自带 tokenizer 上色 | T1 内决定，成本差约 1 个模块 |

> **执行纪律**：T1 开工前只需 Q6 有答案；其余问题不阻塞 T0。
