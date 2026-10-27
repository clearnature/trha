# 上游命令 / 交互架构调查

> **日期**：2026-10-26 · **目的**：为 trha TUI 的分层命令模型找证据，不抄形态。
> **方法**：四路并行读源码（MiMo-Code/opencode、qwen-code/gemini-cli、dsh/Reasonix、codex/ratatui）
> + 同语言近邻 `/data/work/functional-programming/hs/haskell-agent` 精读。
> **对应问题**：`docs/plans/ide-information-architecture.md` §6 的 D1–D9。

---

## 0. 一句话

七个上游里**只有 `hs/haskell-agent` 与我们同语言同框架**（Haskell + brick），它的做法是
**线程倒置**：命令跑在 worker 上，需要人回答时通过 `AppEvent … TMVar` 请求 UI 并阻塞等待。
trha 现在把命令跑在 brick 事件线程上（`Brick.hs:3127` 的 `liftIO`）——这既是 D3 的根因，
也是"命令无法使用"的直接原因。

---

## 1. 各上游怎么表达"层"

| 上游 | 层的表达 | 真栈? | Esc 归属 |
|---|---|---|---|
| opencode | 路由 ADT（**赋值替换**，无历史）+ dialog 单槽（`replace` 写单元素数组 ⇒ 深度恒 0/1）+ `enabled` 谓词门控 | ❌ | dialog 自己的 handler；其余靠 `dialog.stack.length === 0` |
| MiMo-Code | 同上，但移除了集中 keymap，改用每组件 `useKeyboard` + suspend 计数 | ❌ | 同上 |
| qwen-code | `DialogManager` 的 if-chain（33 个 dialog id）+ `dialogsVisible` 30 项 OR | ❌（伪栈） | 各 dialog 自己的 `useKeypress` |
| gemini-cli | 同上（11 个 dialog id，**源码顺序即优先级**） | ❌ | 全局 Esc 在 dialog 可见时 no-op |
| codex | **真栈** `Vec<Box<dyn BottomPaneView>>`，带 child-accept 回退（接受子视图后弹出标记为 `dismiss_after_child_accept` 的父视图） | ✅ | Esc 统一走 `on_ctrl_c` 的 dismiss 路径；视图可 `prefer_esc_to_handle_key_event` 例外 |
| dsh（web/desktop） | 显式 modal 栈 `WeakMap<Document, {element,close}[]>`，只有栈顶收 Esc/Tab | ✅ | 栈顶 capture 阶段独占 |
| Reasonix TUI | 一组 nullable 字段 + 手写 if-chain（9 个面板 × 3 处：onKey / insertPaste / screenKey） | ❌ | 各面板自己吃 esc，兜底 `escape()` |
| **haskell-agent** | **显式 nullable 槽位 + 优先级元组** | ❌ | **元组顺序**决定 |

**结论**：多数上游**不用栈**，但都满足同一条：*同一时刻只有一个层解释按键，且这条规则可枚举*。
trha 的问题不是"没有栈"，而是**规则藏在 if 链里、没有单一表述**（D1）。

---

## 2. 同语言近邻：`haskell-agent` 精读

### 2.1 命令目录（与 trha 同构）

`Command/Types.hs:185`：

```haskell
data SlashCommand = SlashCommand
    { slashName, slashAliases, slashUsage, slashSummary
    , slashTakesArguments, slashDialects, slashRequiredTools }
```

65 条（`Command/Catalog.hs:9` 起，`/model` 别名 `m`、`/theme` 别名 `t`、`/permissions` 等）。
`SlashCatalog` 的注释把关键设计写死了（`Types.hs:196-199`）：
> Tool-backed commands are filtered when the catalog is built, so **the same catalog must be used for parsing, help, and both completion UIs**.

→ 这与 trha 的 `slashRegistry` 完全同构（我们的 picker/help/completion 已同源）。
**但两边都没有"命令要进哪一层"的声明** —— 这正是我们新增 `CommandLayer` 填的空白。

### 2.2 键权：显式优先级元组

`TUI/App/Event.hs:1546-1562`：

```haskell
case (appTextPrompt, appChoice, uiPermission, appMetaConsole) of
    (Just _, _, _, _)             -> handleTextPromptKey event
    (Nothing, Just _, _, _)       -> handleChoiceKey event
    (Nothing, Nothing, Just _, _) -> handlePermissionKey event
    (Nothing, Nothing, Nothing, Just _) -> handleMetaConsoleKey event
    (Nothing, Nothing, Nothing, Nothing) -> handleNormalKey event
```

palette 额外的前置条件（`:1581-1587`）：`commandPaletteAvailable` = 上述四槽全空且无 dictation。
→ **和我们 `escapeOrder` 是同一件事**，只是他们用元组、我们用有序列表。

### 2.3 对话框携带"待回执"

`TUI/Types.hs:528`：

```haskell
data PendingDialog reply overlay = PendingDialog
    { dialogReply :: !reply
    , dialogOverlay :: !overlay }
```

注释：*"An open dialog always owns its reply and any actions it needs. Mapping a dialog edits its
presentation without separating it from those capabilities."*
并且 `dismissPendingChoice`（`:553-560`）规定：**被替换的对话框必须 fail-closed 地回 `Nothing`**，
不许静默丢弃调用者。

> 这条约束 trha 完全没有：我们的 `Dialog` 只有"选了几"（`Int`），没有"谁在等这个答案"。
> 原因是我们让命令跑在 UI 线程上，靠返回值传结果——一旦改成 worker，就必须补上 reply 句柄。

### 2.4 线程倒置（最关键的一条）

worker 侧（`TUI/App/Runtime.hs:1168-1179`）：

```haskell
reply <- newEmptyTMVarIO
enqueueAppEvent runtime (AppAskChoice ChoiceDialog title body initial rows reply)
result <- race (atomically (readTMVar reply)) (refresh (body, rows))
```

UI 侧：`AppEvent` 里 `AppAskChoice … !(TMVar (Maybe Int))`（`Types.hs:177`），
`handleAppEvent` 把槽位填上，按键由 UI 处理，回车/取消时 `putTMVar`。
终端交还也被事件化：`AppSuspend !(IO a) !(TMVar (Either SomeException a))`（`Runtime.hs:1392`）。

**这就是 D3 的正解**：UI 线程只做状态转换，任何可能慢的活儿都在 worker 上，
结果通过 `BChan` 回灌。trha 的 `ctrl+e` 已经这么做了（`suspendAndResume`），
但 35 条落到 `executeCommand` 的命令没有。

### 2.5 事件合批

`AppUiBatch !(NonEmpty UiEvent)`，mailbox 按 `uiFrameDelayMicros = 16000` / 批量上限 256 合批，
delta 流不按 token 逐次渲染（`TUI/App/Mailbox.hs`；`Types.hs:273-284`）。
trha 的 `BChan AppEvent` 目前一条 delta 一次重绘，流式长回复时是 O(n²) 的绘制量。

---

## 3. 其余上游可移植的点

| 来源 | 形态 | 落地到哪 |
|---|---|---|
| codex `bottom_pane/mod.rs:636-655` | 真栈 + `dismiss_after_child_accept` 回退出栈 | 向导叠加选择器（D2） |
| qwen `ui/commands/types.ts:300` | Action 封闭 ADT：`Msg \| Open DialogId \| SubmitPrompt \| ScheduleTool \| Quit` | 命令模块不碰 UI，只产出 Action |
| dsh `ui-commands/src/client/contract.ts:100-130` | `CommandTarget = Local \| Kernel \| KernelWithPopup` | 区分"本地即答"与"下发内核" |
| Reasonix `prefsnav.tsx:168,191` | 每行设置声明 `apply`（immediate/restart/next-turn…）与 `scope` | 设置中心能诚实说"已保存，未生效" |
| codex `app_event.rs:263` | 单一 `AppEvent` enum 承载所有异步结果 | trha 已有 `AppEvent`，需扩到命令结果 |
| codex `slash_command.rs:12-22` | 枚举顺序 = 弹出顺序（`// DO NOT ALPHA-SORT!`） | 我们的 `layerTable` 已是显式顺序 |

---

## 4. 不可移植（避免把别人的债务搬过来）

1. **DOM 的"最内层自动赢"**（capture/bubbling/`querySelectorAll(...).at(-1)`）：brick 没有气泡，必须显式声明。
2. **boolean flag 满屏**：qwen 33 个 dialog id + 30 项 `dialogsVisible` OR、gemini 的 if-chain 即优先级——这正是 D1 的病。
3. **`await DialogPrompt.show()` 协程式向导**：brick 没有协程；同一份逻辑必须写成显式 step 状态机（无"返回上一步"的能力也来自这里）。
4. **存渲染闭包**（`dialog.replace(() => <X/>)`）：brick 组件是 `AppState` 的纯函数，局部状态必须上提到模型。

---

## 5. 对 trha 的三条结论

1. **D1**：8 个上游 8 种写法，但都能收敛成一张有序表 —— `escapeOrder` 方向正确，缺的是让 `Brick.hs` 真的查这张表。
2. **D3**：同语言已有验证过的解法（worker + `TMVar` + `BChan`），不需要发明。
3. **D2**：向导不该是 `appWizard` 这样的私有字段。两条路：进栈（codex 形态），或像 haskell-agent 那样**每个对话框自带 reply 并在优先级表里显式占位**。

---

## 6. 对 `UI/Interaction.hs` 的修订建议（待裁定）

| # | 修订 | 依据 |
|---|---|---|
| R1 | `CommandLayer` 增 `CmdAwait`：需要人力回答的阻塞式请求（审批、确认、提问），由 worker 发起、UI 回答 | haskell-agent `AppAskChoice`；trha 现在把 `/delete` 确认塞进 `CmdPicker`、审批塞进 `CmdAsync` |
| R2 | `Layer` 增两列语义：`stackable`（可否叠加）与 `replaces`（向导是 replace 还是 push） | codex 栈的 child-accept；opencode 的 `replace` 是替换而非入栈 |
| R3 | 不变式升级为可执行断言：**`CmdAsync` 必须在 worker 执行，结果以事件回写**；`CmdAwait` 必须带 reply 句柄 | 同语言先例 + 我们 D8 的病（modelRef 无人读回） |
| R4 | 补 `CmdBatch` 语义：流式 delta 允许合批（16ms/256） | haskell-agent mailbox；trha 现在逐 delta 重绘 |

---

## 7. 学习后的顺序（不变）

D1 统一 escape 路由 → D2 向导入栈/占位 → D3 回合命令异步化。每步先写 spec。
