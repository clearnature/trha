# TUI 移植计划：MiMo-Code 形态 → trha CLI

> 事实输入：[`../reference/mimocode-tui-analysis.md`](../reference/mimocode-tui-analysis.md)（五路源码直读，交叉验证完成）。
> 执行方式：subagent-driven-development 或 executing-plans。步骤用 `- [ ]` 语法。
> **范围声明**：M0 在本计划内给出完整 TDD 任务（可直接执行）；M1–M4 是里程碑契约（验收标准 + 文件结构），每个启动时按本仓库惯例另行细化为独立 TDD 计划——这是 writing-plans 的「跨子系统拆独立计划」规则，不是占位符。

**目标：** 把 trha 的 TUI 从「单文件 1360 行的简陋消息流」升级为 MiMo-Code 形态的终端工作台——真实流式、对话框化、可折叠工具渲染、有成本与上下文可见性。
**架构：** 保留 trha 分层（UI/Bridge/Core）与「纯视图模型 + spec」测试惯例；移植单元是**交互契约与组件形态**（MiMo 是 TS/Solid + opentui，trha 是 Haskell/brick，代码不可搬）。第一阶段先修数据流地基（SSE delta 丢弃是当前硬伤），随后按「对话框系统 → 审批/diff → 侧栏与高级」逐里程碑推进，每个里程碑产出可工作可测试的软件。
**技术栈：** Haskell + brick（现状不变）；新增模块沿 `packages/app/CLI/UI/` 既有目录约定。

---

## 里程碑总览与验收标准

| 里程碑 | 内容 | 验收标准 | 状态 |
| --- | --- | --- | --- |
| **M0 数据流地基** | 消费 SSE text delta、流式渲染、去除 drain-window hack | 对真实 scheduler 发消息：回复**逐 delta 增长**（非整段出现）；无重复渲染；spec 全绿 | 流式与终态收尾已落地；人工验收未做 |
| **M1 核心形态** | 多行输入、markdown 增强、工具卡折叠、token/上下文统计、会话状态 spinner | 输入 1-6 行自适应；markdown 列表/标题/行内样式可见；工具卡可折叠展开；footer 显示 prompt/completion/累计/占用% | 已落地（折叠仅"最近一张"卡） |
| **M2 对话框系统** | UI/Dialog.hs 栈 + escape 层级表；模型/会话/命令面板迁入对话框 | dialog 栈 LIFO + escape 语义表逐条通过；`/models`、`/sessions`、`ctrl+p` 均为浮层，消息流不再被文本列表污染 | 已落地；双击 esc 与真实中断已在 M3.5-2/3 补齐 |
| **M3 审批与 diff** | 权限审批对话框 + unified diff 渲染 + once/always/reject | 审批到达时消息流锁定；diff 正确配色；once/always/reject 走 scheduler `decision` API | 主链路已落地；删除类 always 已移除；diff 行号/宽度阈值已在 M3.5-8 补齐 |
| **M3.5 纠偏与收口**（新增） | 移除 drain window、双击 esc 修正、真实中断、审批安全特例、文档真实性、人工验收 | 下列 8 项逐条通过；文档勾选与代码一致 | **进行中（7/8，仅剩人工验收）** |
| **M4 侧栏与高级** | 侧栏（token/成本/TODO）、@文件补全、leader 键、truecolor 主题、鼠标 | 侧栏 ≥80 列停靠、窄屏浮层；`@` 触发文件补全；主题含 truecolor 调色板 | **完成（M4-1/2/3）** |
| **M5–M10 完整移植**（2026-10-25 重定范围） | MiMo TUI 全形态面：消息流 Part、工具特化渲染、Home/Toast/导出、对话框全集、编辑器 extmark、侧栏九节；建议不移植项单列 | 每阶段纯模块 spec + pty 人工验收；需后端能力的项先落 API 再回填 UI（不做空壳） | **计划已细化（见 §M5–M10），实施待排期** |

---

## 现状快照（2026-10-25 代码核对，非记忆）

| 里程碑 | 真实状态 | 证据 |
| --- | --- | --- |
| M0 | 流式渲染可用；drain window 已由终态等待替代（M3.5-1）；**人工验收仍未做**（3.3 勾选已回退）；spinner 实为内容驱动而非 Tick 驱动 | `Core.SSE.isTerminalPayload`、`Brick.hs` 的 `timeout 250000`、`:603-608` |
| M1 | 五项功能在；工具卡折叠只切"最近一张"，无卡片焦点 | `toggleRecentFold`（`Brick.hs`） |
| M2 | 对话框栈与 escape 表在；`resolveEscape` 实接线只喂 `efStack`（选区/shell/联想恒 False）；双击 esc 已按 Running 布防并在触发后清 armed（M3.5-2）；真实中断已接（M3.5-3） | `UI.Dialog.escWiring`、`Brick.hs` escape 段 |
| M3 | 审批链路（parked → 浮层三选 → decision）与 diff 分类上色在；审批是**居中浮层**而非计划原文的"底部审批条"；删除类命令已无 always（M3.5-4）；diff 行号与 120 列阈值已补（M3.5-8）；reject 附原因经决策**不做**（3.5-5 选 B，需 deny 重放契约） | `UI.Dialog.approvalOptions`、`UI/Render/Diff.hs` |
| M4 | M4-1 侧栏、M4-2 `@` 补全、M4-3 truecolor/leader/鼠标均已落地（顺带补回 M3 漏定义的四条 diff 主题色） | `UI/Layout.hs`、`UI/Render/Sidebar.hs`、`UI/Completion.hs`、`UI/Keys.hs`、`UI/Theme.hs` |

内核事实（决定 M3.5 排期）：
- **无中断 HTTP 端点**：`interrupt: id =>` 只是 `AgentHooks` 回调（供 `interrupt_agent` 工具用）；`abortRequested` 的检查点在 tool 循环内（`packages/scheduler/src/Server/index.ts:1256`）。真中断需新增路由 + 契约登记。
- **decision 只收 approve**：`POST /api/session/:id/decision` 仅读 `{approve}` 或计划的 `{action}`（`index.ts:1499-1530`），拒绝原因没有通道——要做就得改契约。
- 权限规则为 `deny > ask > allow`，pattern 支持 `ToolName` / `ToolName(glob)` / `Bash(command:glob)`（`Permission/permissionRules.ts`），因此"删除类命令不给 always"可在 CLI 侧用纯分类器实现。

---

## M0：数据流地基（本计划内完整展开）

**文件：** 创建 `packages/app/CLI/UI/Event.hs` · 修改 `packages/app/CLI/Bridge/Scheduler.hs:169-216` · 修改 `packages/app/CLI/UI/Brick.hs`（消费侧 + 移除 953-961 的 drain window）· 测试 `packages/app/CLI/test/UI/EventSpec.hs`（新建）

- [x] **任务 1：抽纯事件模块 `UI/Event.hs`（Brick.hs 拆分第一步）**

  - [x] 步骤 1.1：把 `AppEvent`（11 构造子）与 `PendingMsg` 从 `Brick.hs:120-132, 432-439` 移入新模块 `UI/Event.hs`，`Brick.hs` 改为 import。加纯归约函数：

    ```haskell
    -- | 流式增量归约：delta 追加，终态定型。纯函数，可测。
    applyChunk :: StreamChunk -> PendingMsg -> PendingMsg
    applyChunk (ChunkDelta t) pm = pm { pendingText = pendingText pm <> t }
    applyChunk (ChunkDone u)  pm = pm { pendingDone = True, pendingUsage = Just u }
    applyChunk _              pm = pm
    ```

  - [x] 步骤 1.2：写失败测试 `test/UI/EventSpec.hs`：delta 序列追加顺序、ChunkDone 定型、ToolEvent 不影响文本。

  - [x] 步骤 1.3：`cabal test gh-harness-cli` → 新 spec FAIL（模块未接线）→ 接线后 PASS → `git commit -m "refactor(cli): extract UI.Event pure stream reduction"`。

- [x] **任务 2：Bridge 转发 text delta（消灭丢弃点）**

  - [x] 步骤 2.1：修改 `Bridge/Scheduler.hs:204-208`：`SseTextDelta` / `SseMessage` 不再丢弃，经现有回调推给调用方；回调签名对齐 `UI.Event` 的事件类型。保留 `SseUnknown` 报错路径。

  - [x] 步骤 2.2：测试：用 `Core.SSE.feed` 喂一段含 `data: {"type":"text_delta",...}` 的 SSE 字节流 fixture，断言回调收到对应 ChunkDelta 序列（复用 `test/Core/SSESpec.hs` 的 fixture 惯例）。

  - [x] 步骤 2.3：`cabal test` PASS → `git commit -m "feat(cli): forward SSE text deltas to UI"`。

- [x] **任务 3：TUI 消费流式增量 + 帧动画**

  - [x] 步骤 3.1：`Brick.hs` 消息区渲染改读 `pendingText` 逐 delta 增长；busy 期间输入框标签接 spinner 帧序列（`⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏`，`AppEvent Tick` 驱动，100ms）。
    落地偏差：未引入 `Tick` 定时器，实为**内容长度驱动**（`spinnerFrame (T.length (pmContent pm))`，`Brick.hs:603-608`）——零线程、delta 驱动重绘即驱动动画。行为可接受，保留该简化并在此登记。

  - [x] 步骤 3.2：移除 `Brick.hs:953-961` 的 `threadDelay 100_000` drain window——以 `ChunkDone`/`SseMessage` 终态事件收尾（对齐 MiMo 的 step-finish 语义）。
    落地（原勾选一度不实，2026-10-25 由 M3.5-1 补齐）：SSE 终态判定 + 有上限的终态等待替代固定 sleep，TUI 路径已无 `threadDelay`。

  - [ ] 步骤 3.3：手动验收（对真实 scheduler）：发一条长回复，确认逐字增长、无重复段落（若 `/api/agent/step` 整段 reply 与 SSE delta 重复，以 delta 流为准、step 返回仅作 finalize 信号——在 Scheduler.hs 注释记录该契约）。
    **未完成（勾选已回退）**：真实模型下的人工验收尚未执行。转 M3.5-7。

## M1：核心形态（启动时细化，契约如下）——**已完成（2026-10-25）**

> 进度：五项全部落地（spec 256/256）：多行输入与共享历史（`UI/InputHistory.hs`）、markdown 增强（`spanWrap` 替代被 3.0 删除的 widget 级 `wrap`）、工具卡折叠（结构化 `ToolCard` + 内核 `output` 尾部预览，契约 §3 已登记）、token 统计（内核 `usage` 回显 + footer 四段 + 会话索引累计）、spinner 三态（`RunState` 阶梯）。提交 f7a5b82/014fe87/9e4b7c3/f1d2907/0f72c61/8661bff。**待人工验收**：`cabal run trha -- tui` 连真实模型。

- [x] **多行输入**：brick editor `Just 1 → 动态高度`，1-6 行自适应（对齐 MiMo `maxHeight=6`）；`alt+enter` 换行、enter 提交；光标在首行时 ↑ 翻输入历史（复用 REPL 历史文件）。
  落地：editor 限 6 行（brick line-limit 同时是编辑上限与显示上限，`vLimit` 天然自适应）；alt+enter 直投 `handleEditorEvent`（brick 只对纯 `KEnter []` 换行）；↑/↓ 在首/末行翻历史，新增纯模块 `UI/InputHistory.hs`（草稿暂存 + `~/.trha/history` 共享读写，多行条目以换行→反斜杠 n 转义存行）。
- [x] **markdown 增强**：`UI/Render/Markdown.hs` 增列表/标题/行内样式渲染（bold/code 现已解析、只差渲染），纯函数 + spec。
  落地：`MdHeading`/`MdListItem` 解析 + `renderBlocks` 按 span 属性渲染；brick 3.0 **删除了 widget 级 `wrap`**，新增渲染时 `spanWrap`（镜像 `txtWrapWith` 技法：context 宽度 + 渲染时重排，宽字符经 vty wcwidth 计宽，超宽词按字符硬切）。
- [x] **工具卡折叠**：`UI/Render/ToolCard.hs` 增加 collapsed/expanded 两态 + 输出内容行；`AppEvent` 增 toggle 消息；状态存 Map 消息 id。
  落地：`msgTool` 升级为结构化 `ToolCard`（名/参/状态/时长/输出预览）；`msgId`（位置式）与 `appFolds :: Map Int ToolFold`；`ctrl+o` 或空输入 `enter` 切换最近工具卡；内核 tool:update 增 `output` 尾部预览（末 12 行 ≤2KiB，可选字段，已登记 `docs/contracts/protocol-shell-kernel.md` §3 并过 TypesSpec roundtrip + scheduler 受影响 specs）。
  简化登记：没有卡片焦点/命中测试，只能切"最近一张"卡；逐卡折叠进 M5 backlog。
- [x] **token/上下文统计**：`Core/Types.hs` 的 `Usage` 已有 prompt/completion——footer 增 `in/out/累计/占用%` 四段；累计值入 `Core/Transcript.hs` 会话索引。
  落地：内核 agent/step 响应补 `usage` 回显（promptTokens=in；本轮 completion/cacheHit/cacheMiss 增量；cumulativeTokens=session 累计）；Bridge 增 `sendMessageWithUsage`（旧签名保留）；TUI `appUsage`/`appCtxSize`（启动异步拉 /api/models）；footer 新 metric key `usage`（默认启用，En/Zh 各四段，无 echo 时留空）。
- [x] **会话状态 spinner**：idle/awaiting-approval/running 三态显示（为 M3 审批锁定做状态地基）。
  落地：`RunState`/`runState`/`runStateLabel` 纯函数入 `UI/Event.hs`，`drawInput` 按态换标；服务端占位回复被识别后不再当错误。

## M2：对话框系统（启动时细化，契约如下）

> 前置已就绪（2026-10-25）：CLI 已升级 **brick 3.0**（`trha-cli.cabal` 钉 `brick >= 3.0`）——3.0 自带层嵌入组合子 `above` 与 `Brick.Widgets.Menu/MenuBar` 弹出菜单，且鼠标点击不再穿透高层遮罩，对话框/浮层直接受益。参考源码已收录 `3rdparty/brick-3.0/`（注意：3.0 删除了 widget 级 `wrap`，M1-2 以渲染时 `spanWrap` 补位）。

- [x] 新模块 `UI/Dialog.hs`：`DialogStack = [Dialog]`、`stackPush/stackPop/stackTop/stackNull`、**escape 层级表** `resolveEscape`（对齐 MiMo：选区→弹栈→shell→联想→审批；5 秒双击布防 `escPress`——真实中断接 M3 审批锁定）。（2026-10-25 完成，spec 逐条覆盖，278/278）
- [x] 迁移三个既有文本交互进对话框：模型选择器（`/models` 推空栈 + `EvModels` 异步填充）、会话列表（`/sessions`/`EvSessions` 走本地 `SessionSummary`，含标题与累计 token）、命令面板（现有 picker 改浮层，键位对齐 `ctrl+p` + `/`；`PickerState` 已删除）。绘制用 brick 层列表：`drawUI` 首元素 = 顶层，`centerLayer` 居中卡片。（2026-10-25 完成）
- 验收：`escape` 层级表逐条 spec 化（纯状态机测试，不需要渲染）——✅ `UI/DialogSpec.hs`（层级表 5 行 + 双击布防 3 行 + 栈/选择/命令编辑 11 例）。

## M3：审批与 diff（启动时细化，契约如下）——**主链路完成（2026-10-25），收口转 M3.5**

> 进度：审批链路与 diff 分类上色落地（spec 287/287）。链路为「内核 ask 规则 → step 回 `awaiting_approval:` → 消息流锁定 + 居中浮层三选 → `POST /api/session/:id/decision`」。**未兑现**：diff 行号/宽 <120 规则、删除类命令的 always 豁免、reject 附原因、真实中断。

- [x] **权限审批对话框**：到达审批请求时消息流锁定、浮层三选（对齐 MiMo once/always/reject + always 二次确认）；走 scheduler `POST /api/session/:id/decision`（Bridge 已有）。
  落地：`flushPending` 识别 parked 轮（`awaiting_approval:` 前缀）——不再当错误红字，先冲已收内容、`appBusy` 落 False、park `appApproval` 并弹 `DialogApproval`（消息/工具名/参数来自 `EvTool` 的 `REQUIRE_APPROVAL:` 失败事件）；三选项 once/always/reject，`esc` = reject（走 escape 层级表）。always 进 `DialogConfirm` 二次确认，确认后先 `allowAlways`（`GET /api/permissions` 取 rules → 追加 `{kind:"allow",pattern}` → `PUT`；bash/shell 系用 `Bash(command:<cmd>*)`，其余用工具名）再 `decidePlan True`；`EvVerdict` 收口清 `appApproval` + busy（顺带修掉 PlanDenied 卡 busy）。`SsePlan`（`agent:plan`）分类后静默。
  形态更正：计划原文写"底部审批条"，实际实现是 `centerLayer` **居中模态浮层**（更接近 MiMo 的 dialog 形态）。
- [x] **`UI/Render/Diff.hs`（分类部分）**：unified diff 行分类 + added/removed 配色（纯函数 + spec）。
  落地：`DiffClass`（`CAdd`/`CDel`/`CHunk`/`CMeta`/`CPlain`）分类 + `parseDiffLines`；展开态工具卡的输出行按 class 上色，主题新增四属性 `diffAdd/diffRemove/diffHunk/diffMeta`（dark/light 各一套）；DiffSpec 8 例。
- [x] **diff 显示规格**：行号对齐与「宽 <120 用 unified」的显示规则——已由 M3.5-8 完成（见该节）。

## M3.5：纠偏与收口（新增，先于 M4）——**进行中（7/8，仅剩人工验收）**

> 依据：2026-10-25 代码核对发现的 4 处勾选不实、2 处未注记偏离、3 处 MiMo 对齐缺口。原则：**先让计划与代码一致，再往下建**；每项完成即更新勾选与证据行号。

- [x] **3.5-1 移除 drain window**：删掉 `runStepWithTools` 尾部的固定 `threadDelay 100000`。
  落地：SSE 侧新增终态判定——`Core.SSE.isTerminalPayload`（assistant 消息回声 / plan 闸门为终态）+ Bridge `subscribeSessionEventsWithTerminal`；一条连接保序，收到终态即证明此前所有 tool:update 已交付。TUI 收到 step 回复后 `timeout 250000 (takeMVar doneVar)` 有上限等待终态再 `cancel`，无 marker 的旧内核最多多等 250ms。TUI 路径已无 `threadDelay`。
  测试：`SSESpec` 终态分类 1 例、`BridgeDeltaSpec` 终态 sink 1 例（raw-socket fixture）。
- [x] **3.5-2 双击 esc 语义修正**。
  落地：抽出 `UI.Dialog.escWiring :: running -> withinWindow -> armed -> (interrupt, keepArmed)`；`escapeWithoutApproval` 用 `keepArmed` 决定 `appEscLast`（fired 时清空，第三次按下重新布防），且仅 `appBusy && no parked approval` 时布防；空闲 esc 不布防。
  测试：DialogSpec「idle 不布防 / 首按布防 / 二次触发 / 三次只触发一次」4 例。
- [x] **3.5-3 真实中断（跨壳契约）**。
  落地：内核 `POST /api/session/:id/interrupt`（忙则置 `abortRequested` 并回 `{aborted:true}`，空闲回 false 不置标志）；`runTurn` 的 `finally` 清标志，迟到的中断不泄漏到下一轮。Bridge `interruptSession`；CLI 在双击 esc 时异步调用、状态栏 "Interrupting…"；旧的 "cancel lands in M3" 文案已删。契约 §2 已登记端点与语义。
  测试：`packages/scheduler/test/interrupt.test.ts` 2 例（空闲拒绝且不毒化下一轮 / 忙时置位且轮末清除）。
  限制（已在契约写明）：检查点在**轮次之间**，不能打断正在进行的单次模型生成。
- [x] **3.5-4 删除类命令不给 always**。
  落地：`UI.Dialog.approvalOptions :: String -> [Text] -> [ApprovalOption]` + `isDestructiveShell`（bash/shell/run_shell 的首参数；跳过 sudo/doas/env/赋值前缀；rm/rmdir/del/erase/format/mkfs/dd/shred/truncate/mv、`git clean`、`git reset --hard`）；`dialogCount`、绘制行与 `dialogActivate` 全部改为按选项表分支。
  测试：DialogSpec 审批选项 7 例（含 `rm -rf`、`sudo rm`、`FOO=1 mv`、git 两类、非 shell 工具、计数与夹取）。
- [x] **3.5-5 reject 附原因（决策：选 B，不做）**：MiMo 的 reject 可填原因，当前 decision 端点只收 `{approve}`。
  决定：**方案 B**。核查结论——拒绝路径在编排层直接返回 `{status:"denied"}` 并结束本轮（不重放 turn），
  原因没有任何消费者（模型看不到、转写里也没有对应工具结果）。要让它有意义，需要新增「deny 重放」
  语义：编排层把 `denied: <reason>` 作为工具结果回灌并再跑一轮，同时内核 FSM 与三个外壳都要接受这条新路径
  （Desktop/Web 现有 deny 语义会被改变）。超过半天且属跨壳契约变更，按计划 B 档记录。
  若 M5 拾起，最小设计是：`POST /decision {approve:false, reason?}` → 编排层构造 tool 结果 →
  `runTurn` 续跑；契约 §2 同步。
- [x] **3.5-6 文档真实性**：已回退 M0-3.2/3.3 的假勾选、登记 spinner 内容驱动偏差、把 M3 形态改为浮层并把 diff 拆成"已做/未做"两项；本轮随 3.5-1…4 同步勾选与证据。
- [ ] **3.5-7 人工验收清单（用户执行，回填本节）**：
  > 与 M4-1 开发并行执行（运行时指示）；未通过前 M3.5 不算收口。
  - [ ] `cabal run trha -- tui` 连真实模型：长回复逐字增长、无重复段落
  - [ ] 工具卡：`ctrl+o` / 空输入 `enter` 折叠展开，输出尾部预览正确；diff 类输出有增删配色（宽屏 ≥120 列带行号栏）
  - [ ] footer：in / out / total / ctx% 数值合理
  - [ ] 配一条 ask 规则：审批浮层弹出、消息流不可输入、once / always / reject 三路结果正确；always 后同命令不再询问
  - [ ] 删除类命令（`rm -rf`）的审批只有 once/reject 两项，没有 always
  - [ ] 运行中双击 `esc`：状态栏显示 "Interrupting…"，长工具循环以 `(interrupted)` 收尾、busy 解除；空闲按 `esc` 不触发中断
- [x] **3.5-8 diff 显示规格**：行号对齐与宽度阈值。
  落地：`UI.Render.Diff` 增 `hunkStart`/`numberDiff`/`DiffRow`（旧/新行号分别推进：context 双增、删除只推旧、新增只推新；hunk 外的 meta 行不编号）、`diffLayout`/`renderDiffRow`（**<120 列 inline unified 无行号，≥120 列加 4+4 行号栏**）与 `looksLikeDiff`（以 hunk 头为准，避免把 `-` 列表误判成 diff）。工具卡展开态在 `looksLikeDiff` 时改走 `diffWidget`（渲染时取 `availWidthL` 定布局，逐行按 class 上色）。
  与 MiMo 的差异（已登记）：MiMo 在宽屏切 side-by-side，这里保持 unified 只加行号栏——工具卡展示的是输出尾部预览，配对 hunk 没有收益。
  测试：DiffSpec 新增 12 例（hunk 解析含无计数形式、编号推进、hunk 外不编号、阈值两侧、两种渲染、looksLikeDiff）。

## M4：侧栏与高级（拆三刀，逐刀可交付）

### M4-1 侧栏——**已完成（2026-10-25）**

- [x] 宽度策略抽纯模块 `UI/Layout.hs`：≥80 列停靠 / 窄屏浮层（MiMo 参考 42 列）。
  落地：`SidebarState` 为 **Auto/Open/Closed**（Auto = 宽屏停靠、窄屏隐藏，避免一进来就被浮层遮住；`ctrl+b` 第一次打开、之后开合）。`sidebarPlacement` 80 列为界；停靠宽 = 屏宽 1/3 夹在 24..42（80 列时消息区仍有 51 列），浮层宽 ≤42 且永不为 0；`sidebarRender` 产出 `RenderDocked/RenderOverlay/RenderNone`，`messageWidth` 只对停靠扣减。布局 spec 覆盖 79/80 两侧、宽度夹取、极窄终端与开合语义。
- [x] 内容三节：Context、TODO、会话信息。
  落地：纯渲染模块 `UI/Render/Sidebar.hs`（`sidebarLines`）——Context 显示 in/out/total 与 `ctx %`（复用 `Usage`/`appCtxSize`；**成本/TPS 暂无数据源，未显示**），TODO 来自 `session.teamTasks`（`○/◐/●` 三态，空则 "No tasks"），Session 显示 id + 本地转写标题 + 模型。Brick 侧 `drawSidebar` 加边框标题；停靠走 `hBox`，浮层走独立层 + `V.translate` 右对齐（未覆盖区域透明）。
- [x] TODO 数据接线：Bridge `fetchTeamTasks`（GET `/api/session/:id` 的 `teamTasks`，缺字段按空列表），新增 `EvTodos`/`EvSessionTitle`；每轮结束与 resume 时刷新（标题取自本地转写 `listLocalSessions`）。
- [x] 验收：≥80 列停靠、窄屏浮层可开合；布局 spec 覆盖两侧阈值；三节无数据时显示空态（`no usage yet` / `No tasks` / `no session`）且不崩。
  测试：`LayoutSpec` 11 例、`SidebarSpec` 7 例；总计 331/331。

### M4-2 `@` 文件补全——**已完成（2026-10-25）**

- [x] 纯模块 `UI/Completion.hs`：cwd 递归索引（忽略 `.git`/`node_modules`/`dist-newstyle`/`.stack-work`/`__pycache__`/`.venv`/`target`，深度 6、条目 4000 上限）、查询过滤与排序、token 定位与替换。
  落地：`buildIndex`（规范化分隔符、任意层级忽略、深度/条目预算、去重排序）；`completeIndex`（大小写不敏感；路径前缀 > 基名前缀 > 子串，同档按长度再按字典序）；`completionQuery`（光标所在 `@token`，要求 `@` 在行首或空白后）；`applyCompletion`；弹层态 `completionPopup`/`moveCompletion`/`selectedCompletion`/`applySelected`。
- [x] 交互：输入 `@` 触发浮层，↑/↓ 选择，Enter 插入路径，Esc 关闭（按 MiMo 层级表先于中断布防）。
  落地：索引启动时异步扫描（`EvCompletionIndex`，不阻塞输入）；浮层渲染在输入框上方（`drawCompletion`，最多 8 条，带选中标记）；任何编辑键后按光标位置重算弹层；插入目录保留尾部 `/`，可继续补全下一级。
  简化登记（计划允许的降级）：无 extmark，插入后光标落到文本末尾；弹层是普通 widget 而非 `DialogStack` 浮层。
- [x] 验收：`@` 弹层 + 过滤 + 插入；纯模块 spec。
  测试：`CompletionSpec` 22 例（索引 5 / 过滤排序 5 / token 定位 6 / 替换 2 / 弹层 4），总计 353/353。
  待人工：输入 `@` 弹层出现、↑/↓ 选择、Enter 插入（目录后可继续补全）、Esc 只关弹层不布防中断。

### M4-3 主题 / leader / 鼠标——**已完成（2026-10-25）**

- [x] truecolor 调色板：`TermColor` 增 `RGB Int Int Int`；`supportsTrueColor` 读 `COLORTERM`（truecolor/24bit）；`themeFor name supported` 在支持时用 RGB 覆盖表升级，否则保持 ANSI；dark/light 各一套 Tokyo Night / 浅色 RGB 值；`vtyFg` 接 `rgbColor`。
  **顺带修掉一个 M3 留下的真实缺口**：`themeAttrNames` 与 diff 渲染一直在用 `diffAdd/diffRemove/diffHunk/diffMeta`，但两个调色板从未定义这四个角色，`roleColor` 一直回退成白色——现已补齐并加“调色板完整性”spec 防回归。
- [x] leader 键：纯表 `UI/Keys.hs`（`leaderResolve`/`leaderHelp`）；`ctrl+x` 布防，下一键执行 `b` 侧栏 / `m` 模型 / `s` 会话 / `,` 设置 / `?` 帮助 / `i` 中断，`esc` 或未绑定键取消；状态栏显示提示（中英各一）。
- [x] 鼠标滚动：`EvMouseDown` 的 `BScrollUp/BScrollDown` 滚动消息区 3 行（终端是否上报鼠标由 vty/宿主决定，待人工确认）。
- [x] 验收：主题切换可见且两套预设完整；leader 表 spec 逐条；滚轮滚动消息区。
  测试：`KeysSpec` 3 例、`ThemeSpec` 新增 8 例（完整性 2 / truecolor 4 / diff 角色 2），总计 362/362。
  待人工：真实终端 `COLORTERM=truecolor` 下颜色、`ctrl+x` 各键位、滚轮滚动。

## 热修（2026-10-25）：卡 Thinking / 无法连续对话 / 输入框过高

真实模型 + pty 驱动 TUI 复现并修复（用户报告）：

- **每轮结束被重新置忙**：`flushPending` 写的是 `appBusy = not parked`——正常回复时
  `parked=False`，于是 `busy=True`，输入框永远停在 "Thinking…"。改为始终 `False`。
- **收尾与 SSE 竞态**：终态 `ChunkDone` 曾在等待 SSE 终态之前发出，晚到的 delta
  又新建 pending 块，再也没有事件收尾。改为 **step 的整段 reply 是权威文本**：
  SSE delta 只做实时预览，step 返回后写 `EvFinalReply` 覆盖 pending 再 `ChunkDone`；
  `appendDelta` 在 `busy=False` 时直接丢弃迟到 delta。
- **取消 SSE 污染共享连接池**：`killThread` 打死读线程时它可能正处在 http-client 的
  连接记账中，导致下一轮 step 永久等待（服务端已答、客户端收不到）。SSE 订阅改用
  **私有 Manager**；POST 统一加 `Connection: close`（POST 不可安全重试，不复用陈旧连接）。
- **输入框固定 6 行**：brick 的 editor line-limit 同时是**固定高度**（`vLimit 6`），
  空输入也占 6 行。对照 MiMo prompt `textarea minHeight=1 maxHeight=6`、codex
  `Constraint::Length(input_height)`、gemini Composer 后，改为按当前行数
  `vLimit (max 1 (min 6 lines))`，空输入恢复 1 行。
- **斜杠命令改为内联列表**（对齐 MiMo）：输入 `/` 或 `ctrl+p` 时，命令列表显示在
  **输入框左侧上方**（左对齐、随输入过滤、↑/↓ 选择、Enter 执行、Esc 只关列表），
  不再是居中的模态 picker；复用 `DialogCommands` 的纯状态机（过滤/选择都有既有 spec）。
  后续修正：`ctrl+p` 现在写入与 `/` 相同的编辑器内容，两条路径是**同一份列表**；
  空输入时 **skills 排在命令前**，列表随选中项滚动（不再只显示前 8 条）；过滤使用
  去掉前导 `/` 的关键词，`/brooks` 能直接命中 skill。
- **Skills 默认支持 `.agents`**（对齐 MiMo 的开放标准）：新增 `UI/Skills.hs`，扫描
  `<cwd>/.agents/skills`、`<cwd>/.trha/skills`、`$HOME/.agents/skills`、
  `$HOME/.trha/skills`、`TRHA_SKILLS_DIR`；支持 `<name>/SKILL.md`（frontmatter
  `name`/`description`）与 `<name>.md`，同名以项目目录优先。选中后把 SKILL.md 正文
  作为用户回合发送（与 MiMo 的 slash 调用同契约）。启动时异步扫描（`EvSkills`）。
- **web_search 的 `fetch failed`**：该工具默认回退 DuckDuckGo HTML，未配置
  `TRHA_SEARX_URL` 且网络不可达时只报原始 undici 错误。现在错误信息附带
  “TRHA_SEARX_URL 未设置、DuckDuckGo 回退不可达”的可操作提示；env 已登记到
  `docs/contracts/tool-catalog.md`。
- **Anthropic 流式协议不生效**：`anthropicRequestBody` 从未带 `"stream": true`，
  请求实际是阻塞的，SSE 解析器拿不到帧——`deepseek-anthropic` 只剩一个 `[DONE]`。
  修复后实测三条 wire（openai/anthropic/responses）的 kernel 流式端点都返回内容。
- **协议切换矩阵（真实 DeepSeek，经 scheduler → 内核）**：

  | provider | 纯文本 | 工具调用 |
  |---|---|---|
  | `deepseek`（openai） | MATRIX_OK | bash 执行 → DONE，1 tool 消息 |
  | `deepseek-anthropic` | MATRIX_OK | bash 执行 → DONE，1 tool 消息 |
  | `deepseek-responses` | MATRIX_OK | bash 执行 → DONE，1 tool 消息 |

  期间修掉的真实协议缺口（均以 stub 回归测试锁定在
  `packages/app/Desktop/test/provider-stream.test.ts`）：
  1. Anthropic 流式漏 `stream:true`（内容全丢）。
  2. Anthropic 工具轮 400：DeepSeek thinking 模式要求把 `thinking` 块（含签名）回传。
     **已实现完整回放**：`signature_delta`/`thinking` 块被捕获为
     `ChunkReasoningSignature`，经内核 OpenAI 形帧的 `reasoning_signature`、
     scheduler 的 assistant 消息字段一路带回，下一轮由 `toAnthropicMessages`
     原样拼回 thinking 块；thinking 只在“工具轮缺签名”的历史会话里禁用。
  3. Anthropic/Responses 流式 tool 轮丢失供应商 id → 回传 `tool_use_id`/`call_id` 为空，
     上游 400。现在两个解析器都保留 index + id（`ChunkToolCallAt`），聚合与 SSE
     发射器也不再合成/丢弃 id。
  4. Anthropic/Responses 的原生流式端点此前把 `tools` 丢成 `[]`（只有 OpenAI 端点转发）；
     现按各自 wire 的形状解析并透传。
- 证据：pty 驱动真实 TUI 连发两轮，transcript 记录 2 条 assistant 回复；`/provider`
  切换后 footer 显示 `deepseek/deepseek-flash`；最终输入框标签回到 ` Input `；
  `/` 与 `ctrl+p` 都弹出命令列表（`/help`、`/provider`、`/sessions` 可见）。
  cabal 372/372 + 内核 308/0；scheduler typecheck + approval/interrupt/workspace 12/12；
  `KERNEL_BUILD=1 vitest provider-stream` 通过。

### 技能选择语义（2026-10-25 修复）

- **选中 ≠ 发送**：`/` 列表里按 Enter 选技能，现在只把 `/skill:<name> ` 填进输入框
  （MiMo `DialogSkill` 的 `input.setText("/"+name+" ")` 语义），**不再**读文件并立刻起轮；
  再按 Enter 才执行。触发词带空格后列表即关闭（MiMo autocomplete 同一规则）。
- **执行时的可见面**：transcript/消息流显示可见触发词 `/skill:<name> <args>`，
  技能正文（SKILL.md）作为模型上下文发送 —— 与 MiMo 的「可见文本 + 正文注入」切分一致；
  文件读不到时给系统提示而不是发一轮空内容。
- 证据：`UI.SkillsSpec` 新增 `parseSkillInvocation` / `skillTurn` 6 例；`cabal test trha-cli-test` **383/0**。
- **内核侧同源（2026-10-25）**：`skill` 工具改走 `packages/scheduler/src/Server/skills.ts`，扫描链与 CLI
  的 `UI.Skills.skillDirList` 完全一致（项目 `.agents/skills` → 项目 `.trha/skills` → `$HOME/.agents/skills`
  → `$HOME/.trha/skills` → `TRHA_SKILLS_DIR`），支持 `<name>/SKILL.md` 与 `<name>.md`、frontmatter
  `name`/`description`，同名项目优先；`TRHA_SKILLS_DIR` 由「覆盖默认目录」改为「追加」。
  证据：`test/skills.test.ts` 12 例；`vitest run test/skills.test.ts test/standard-tools.test.ts
  test/standard-tools-guards.test.ts` → **30/0**；`tsc --noEmit` EXIT=0。

## M4-4 供应商 / 模型切换（2026-10-25）——**已落地，设置面待补齐**

- [x] **请求下发**：`sendMessageWithTarget` 在 `/api/agent/step` 里带 `provider`/`model`
  （scheduler 早已接受并透传）；旧 `sendMessageWithUsage` 保留委托。
- [x] **供应商选择面**：`Core.Types.ProviderInfo` + `providerStoreToList`（解析
  `{"providers":[…]}`）；Bridge `listProviders`（经 scheduler 转发内核
  `/api/providers`）；`DialogProviders` 弹层（`/provider` 或 leader `p`），选中后
  `modelForProvider` 保留当前模型或回落到 provider 默认值；footer/侧栏显示
  `provider/model`。
- [x] **模型选择按供应商收敛**：选中 provider 后 `/models` 直接用它的 `models`
  与 `contextWindow`，不再发 `/api/models`；未选 provider 时保持原静态列表。
- [x] **审批重放保留目标**：scheduler 的 `pendingApproval` 现在存
  `provider/model/genParams`，批准后重放同一目标（否则会悄悄回落到 inUse 默认）。
  测试：`approval-gate` 新增 1 例（批准后内核收到 `deepseek-anthropic`/`deepseek-flash`）。
- [x] **新增 / 编辑 / 持久化（2026-10-25）**：
  - `/provider` 列表内 `a` 打开新增向导、`e` 编辑当前行；6 步向导（name / kind /
    baseUrl / models / default / apiKey），提交走 `POST /api/providers`（Bridge
    `saveProvider`），内核返回新注册表后刷新列表。空 apiKey 表示保留原密钥。
  - 选择持久化：`configProvider`/`configModel` 写入 `~/.trha/settings.yaml`
    （`/provider` 选择与 `/model` 都会保存），重启后按保存值初始化。
  - 验证：pty 实测新增向导保存出 `zz-test`、编辑向导预填、选中后 footer 显示
    `deepseek/deepseek-flash` 且 settings 落盘 `configProvider: deepseek`；
    (测试 provider 已通过 `/providers/remove` 清理)。
- [ ] **仍未做（对照 MiMo）**：设置面板里的独立 Provider 页签、删除确认、模型能力/
  思考开关。



## M5–M10：完整移植 MiMo TUI 形态面（2026-10-25 重定范围）

> 依据：`../reference/mimocode-tui-analysis.md`（五路源码直读）+ 本轮对
> `/data/training/cli/MiMo-Code/packages/cli/src/cli/cmd/tui`（203 文件）的目录清单核对。
> 口径：**先做不需要后端改动的形态**，需要 scheduler/内核新能力的项单列依赖，不做空壳 UI。
> 归属：`A` = 纯 CLI（Haskell/brick）；`B` = 需 scheduler（TS）新端点/事件；`C` = 需内核改动；`D` = 建议不移植。

### 进度（2026-10-25 第二批）：M5-1/2/3 已接

- **M5-1 reasoning 卡**：内核已有 `ChunkReasoning` → 内核 SSE `reasoning_content`；scheduler
  `queryModelStream` 新增第三个回调实时转发 → `agent:reasoning`（载荷 `{sessionId, reasoning}`）；
  CLI `Core.SSE` 分类为 `SseReasoning`，累积到 `PendingMsg.pmThinking`，轮末生成
  `role="thinking"` 消息（前 3 行 + 字数）。
- **M5-2 step 分隔**：`agent:model-request` 加入 SSE 白名单；CLI 渲染
  `── round N · X msgs · Y tools ──`（新一轮开始时先落定上一轮内容）。
- **M5-3 compaction 卡**：`agent:context`（trigger / savedTokens）加入白名单，CLI 渲染
  `[context]` 卡。
- **M5-4 retry 卡**：✅ scheduler 新增 `Server/retry.ts`（429/5xx/timeout 退避重试，
  ECONNREFUSED 不重试以保住离线回退），发出 `agent:retry`；CLI 渲染 `role="retry"` 行
  （`retry 1/3 in 500ms — reason`）。证据：`test/retry.test.ts` 7 例、`Core.SSESpec` 2 例。

### M5 消息流完整形态（A，少量 B）

> **进度（2026-10-25 第一批）**：M5-5 错误分类 ✅、M5-6 patch 卡 ✅（edit 结果现在附
> unified diff，展开态走 `diffWidget`，折叠态显示 `+N/−M`）、M5-8 present/structured
> 卡 ✅、M5-9 消息 footer ✅（model + in/out）。M5-1/2/3/4（reasoning / step /
> compaction / retry）**需 scheduler 事件**，未做；M5-7 file part 后置（与 M9 附件同批）。

| # | 原子 | MiMo 对照 | 现状 | 依赖 |
|---|---|---|---|---|
| M5-1 | reasoning/thinking 卡（折叠 + 时长 + subtle 配色） | `ReasoningPart`、`Thinking` spinner→Thought | 内核有 `reasoning_content`/`ChunkReasoningSignature`，CLI 未消费 | B：SSE/step 需要 reasoning 增量事件 |
| M5-2 | step 分隔与每轮元信息（round、token、duration、model） | `step-start`/`step-finish` Part + message footer | 只有 footer 累计 usage | B：scheduler 需发 round 边界事件 |
| M5-3 | compaction 卡（摘要 + `prefixResets` 代价） | `CompactionPart` | 无 UI | B：contextGovernor 触发时发事件 |
| M5-4 | retry 卡（失败原因/退避） | `RetryPart` | 无 | B：scheduler 重试路径 |
| M5-5 | 错误分类卡（rate-limit vs 普通 error） | `errorKind()` | 只有 `error` 角色 | A |
| M5-6 | patch 卡（edit/write 的 diff 结果） | `PatchPart` + `<diff>` | `UI.Render.Diff` 已能渲染 diff | A |
| M5-7 | file part（附件/图片引用） | `FilePart` + `source` | 无 | A（粘贴图片另见 M9） |
| M5-8 | structured output 折叠卡 | `StructuredOutput` | 无 | A |
| M5-9 | 消息级 footer（时间/agent/model/queued 标记） | message footer | 时间有 | A |

### M6 工具渲染特化 + 逐卡折叠（A）

> **进度（2026-10-25 第一批）**：M6-1…M6-6 ✅（`UI.Render.ToolSummary`：shell/read/
> search/edit/write/net/agent/ask/skill/present/plan 十一类，折叠态家族化摘要、展开态
> 详情行、present 卡跳过原始载荷）；M6-8 ✅ 逐卡折叠（`appCardFocus` + `alt+↑/↓` 移动 +
> `ctrl+o`/空输入 Enter 切换，纯函数 `nextCardFocus` 有 spec）。M6-7 的
> `shouldHideTool`（完成后隐藏低噪音工具）未做。

MiMo 的 17 个 `Match`（`routes/session/index.tsx:2278-2326`）在 trha 的对应工具名：

| # | 原子 | MiMo 工具 | trha 工具 | 渲染 |
|---|---|---|---|---|
| M6-1 | shell 卡（输出折叠、退出码、耗时） | `bash`/`exec_command` | `bash` | 命令 + 尾部输出 + exit |
| M6-2 | 读/搜卡（行数、命中数、路径高亮） | `read`/`glob`/`grep`/`codesearch` | 同名 | 单行摘要 + 展开内容 |
| M6-3 | 编辑卡（diff 上色，窄屏 inline / 宽屏行号） | `edit`/`apply_patch`/`write` | `edit`/`write`/`unified_edit` | 复用 `UI.Render.Diff` |
| M6-4 | 网络卡（状态码/域名/字符数） | `webfetch`/`websearch` | `web_fetch`/`web_search` | 摘要行 |
| M6-5 | 子智能体卡（任务树、跳转子会话） | `task`/`actor`/`workflow` | `subagent`/`workflow`/`team_task_*` | 摘要 + 会话 id |
| M6-6 | 提问/技能/计划卡 | `question`/`skill`/`exit_plan_mode` | `ask_user_question`/`skill`/`exit_plan_mode` | 复用现有卡 |
| M6-7 | 通用兜底 + `shouldHideTool`（完成后可隐藏） | `GenericTool` | 现有通用卡 | 保留为默认 |
| M6-8 | **逐卡折叠**（卡片焦点/命中测试，替代"最近一张"） | 卡片焦点模型 | `toggleRecentFold` | `appFolds :: Map Int ToolFold` 已就位，补焦点与键位 |

### M7 外壳结构（A；rename/tag 为 B）

| # | 原子 | 内容 | 依赖 |
|---|---|---|---|
| M7-1 | Home 路由（logo、最近会话、tips、欢迎、`--prompt` 自动提交） | 双路由（Home ↔ Session） | ✅ 已落地：`Route` + `drawHome`（logo/最近会话/提示）；非空提交切到 Session；`/home` 返回并刷新 |
| M7-2 | Toast 通知（info/warn/error，3s 自动消失） | `ui/toast.tsx` | ✅ 已落地：`appToast` + `showToast`（3s 定时器带时间戳防旧定时器）；触发点：模式切换、provider 保存、删除会话、`/clear`、`/export` |
| M7-3 | 导出转写（markdown / json，对话框选格式与范围） | `dialog-export-options` | ✅ 已落地：`Core.Export`（`exportMarkdown`/`exportJson`/`defaultExportName`）+ `/export [json\|md] [path]`（默认 `~/.trha/exports/`） |
| M7-4 | 草稿 stash（手动暂存 + 路由切换自动暂存） | `prompt/stash.tsx`、`dialog-stash` | ✅ 已落地：`UI.Stash`（push/pop/list、去重、50 条上限、`~/.trha/stash.jsonl` 原子写）+ `/stash [pop\|list]` |
| M7-5 | 恢复流（失败候选提示，而非只打印一行） | ✅ 已落地：`resumeSession` 失败时给出最近会话候选 + 建议，并 Toast 提示 | A |
| M7-6 | 会话 rename / tag / delete 确认 | ✅ rename/tag/delete 全部落地：scheduler `POST /api/session/:id/meta`（`title`/`tags`，随 stateDir 持久化）+ CLI `/rename <title>`、`/tag <tag...>`；`/delete <id>` 弹 `DialogConfirm`，确认后才删除（`appPendingDelete`） | A/B |
| M7-7 | 窗口标题（会话名 + busy 标记） | ✅ 已落地：`setWindowTitle`（OSC 0），会话创建/恢复写 `trha · <id>`，发送时写 `● trha · <id>` | A |

### M8 对话框与设置补全（A/B 混合）

| # | 原子 | 依赖 |
|---|---|---|
| M8-1 | 模型选择：Favorites/Recent 分区、模糊搜索、收藏持久化 | ✅ 已落地：`UI.ModelPrefs`（`~/.trha/models.json`）+ `/fav [model]` + 对话框 `★` 标记与 favourite→recent→其余排序 |
| M8-2 | 主题列表对话框（含预览、持久化） | ✅ 已落地：`/theme` 无参打开 `DialogThemes`（32 套、↑/↓、Enter 切换并写 settings、当前项标 `current`）；颜色预览未做 |
| M8-3 | 命令面板：frecency 排序、分类、拼音匹配 | ✅ frecency 已落地（`UI.Frecency`、`~/.trha/frecency.json`、`handleSlash`/`submitSkill` 计数、稳定排序）；分类/拼音未做 |
| M8-4 | 上下文限额 / 审批超时档（写入 settings） | A（键已在 `settings.yaml`） |
| M8-5 | 技能对话框（替代内联列表；当前内联列表保留） | ✅ 已落地：`DialogSkills` 浮层（`/skills`，↑/↓ 选择、Enter 填入 `/skill:<name> `） |
| M8-6 | 状态面板（LSP/MCP 连接状态） | **B**：scheduler 需状态端点 |
| M8-7 | MCP 开关（增删/启停 server） | **B**：scheduler 需管理端点 |
| M8-8 | Timeline / fork / rewind | **B**：scheduler 需会话分支 API |
| M8-9 | 子 agent 对话框（列表、消息、状态） | **B**：scheduler 需 agent 视图端点（`list_agents` 已有部分） |
| M8-10 | provider/agent/variant/worktree/workspace 对话框 | B（部分已有 provider） |
| M8-11 | reject 附原因（跨壳契约变更） | ✅ 已落地：内核 `DecisionReq.reason`（响应回显）→ scheduler `/decision` 透传 → CLI `/deny <reason>`（`denyPlanWithReason`）；`plan-forwarding` 断言内核收到 reason | A/B |
| M8-12 | 权限姿态（Shift+Tab 五态 / Ctrl+Y YOLO） | ✅ 已落地：scheduler `Permission/modes.ts` + `/api/session/:id/mode`；CLI 状态栏与键位见 M10-4 |

### M9 编辑器增强（A；ghost/predict 为 B）

| # | 原子 | 依赖 |
|---|---|---|
| M9-1 | extmark 风格占位：`@文件`、`/命令`、`$agent` 作为不可分割 token | A |
| M9-2 | 大段粘贴折叠为占位，提交时展开 | A |
| M9-3 | 补全 frecency 排序 + `file.ts#L10-L20` 行号 | A |
| M9-4 | shell 模式（`!` 前缀，直接跑 bash 不进模型） | ✅ 已落地：`shellCommandOf` + `runShellCommand`（`bash -lc`，120s/20k 上限，非零退出码显示） |
| M9-5 | `$agent` 补全与子会话派发 | B（agents 端点） |
| M9-6 | ghost 预测（idle 时预测下一句，Tab 接受） | **B**：scheduler 需 `predict` |
| M9-7 | `ctrl+e` 外部编辑器 | ✅ 已落地：临时文件 + `$EDITOR`/`$VISUAL`（默认 `vi`），`suspendAndResume` 交还终端，保存后回填输入框 |
| M9-8 | 剪贴板图片（粘贴为附件）+ 终端图片协议 | 🟡 粘贴已落地：`ctrl+v` 依次尝试 `wl-paste`/`xclip`/`pngpaste` → 保存到 `~/.trha/paste/*.png` 并在输入框插入 `[image: path]`；模型多模态通道与终端图片协议未接 | A/B |
| M9-9 | 语音输入 / VAD / voice-edit | 🟡 录音入口已落地：`ctrl+r` 用 `arecord` 录 5s（16 kHz mono）到 `~/.trha/voice/*.wav`，插入 `[voice: path]`；VAD、voice-edit 与转写需外部服务 | B+ |

### M10 侧栏九节与高级（A/B 混合）

| # | 原子 | 现状 | 依赖 |
|---|---|---|---|
| M10-1 | Sidebar：CWD / Files / Goal / Instructions | 只有 Context/TODO/Session | ✅ 已落地七节：Context / CWD / Files / Goal / Instructions / TODO / Session（`EvSidebarInfo` + `fetchSessionInfo`） |
| M10-2 | Sidebar：Task 树（team task / subagent 树） | ✅ 已落地：`Agents` 节 + `fetchAgents`（`/api/sessions` 的 `parentId`）+ `agentTreeLines`（缩进树、当前会话 ●、上限 8 行）；team tasks 仍在 TODO 节 | A |
| M10-3 | Sidebar：LSP / MCP 状态 | ✅ 已落地：scheduler `GET /api/mcp/status`（configured/connected）与 `GET /api/lsp/status`（running/diagnostics）+ 侧栏 `Services` 节 | A |
| M10-4 | Sidebar：TPS / 成本（footer 已有 token） | ✅ TPS 已落地：`FooterLive.flTps` + `tps` metric（completion tokens / 本轮耗时）；成本需定价表，未做 | A |
| M10-4b | 状态栏缓存/上下文/压缩三段 + 权限姿态标签（Reasonix 形态） | ✅ 已落地：`Footer` 新增 `mode/cache/ctx/compact`；`/api/session/:id/mode`；另加**每轮统计行**（`Core.TurnStats.turnSummary`：`本轮 … tok · in · cached · new · out · reasoning · ≈¥… · 低峰/高峰`，TUI 与 REPL 均显示） | A |
| M10-5 | 鼠标选区/复制、滚动加速、滚动条 | 只有滚轮滚动 | A（vty 能力所限，能做的做） |
| M10-6 | 声音反馈（成功/失败 bell，可配） | ✅ 已落地：`configBell`；回复完成与出错时各响一次（`\a`） | A |
| M10-7 | 主题 32 套 / locale 17 种 | ✅ 主题 32/32；locale 支持集（2026-10-26 用户裁定）= **En / zh-Hans / zh-Hant / Français / Español / Русский / ไทย / မြန်မာ**；藏语（Bo）与彝文（Ii）为骨架；**ja / ko / de / it / pt / pl / tr / vi / id / uk 已剔除** | A |

> **时间显示规范（2026-10-26）**：本地时间带系统时区缩写（`07:31:12 CST`，无缩写时 `UTC+08:00`）；transcript 存储保持 ISO `…Z`（UTC，可解析）；`/export` 头部注明 `Times are UTC (Z)`；低峰判断固定 UTC+8 00:30–08:30。

> **2026-10-25 两主分支对比**（`/home/yanli/work/DeepSeek-Reasonix`）：
> `fork/studio` 当前树已无 `internal/cli`（338 文件在 `refactor: the kernel's packages live in the layer they belong to` 中整体移除），因此交互以 `origin/main-v2` 为准。
> main-v2 有 52 个 slash 命令、30 个键位；本轮补齐 `/copy`（剪贴板，xclip/wl-copy/pbcopy 回退）、`/verbose`（全展开工具卡）、`/todo`（团队任务）、`/tree`（代理会话树）。

### 建议不移植（D，逐条等确认）

> 2026-10-25 用户选择：**语音与图片协议保留**（见 M9-8 / M9-9），其余按下表建议不移植。

| 项 | 理由 |
|---|---|
| 登录 / 商业 upsell（`dialog-mimo-login`、`dialog-go-upsell`、`dialog-agreement`、`dialog-console-org`） | MiMo 产品特有 |
| 品牌装饰（`logo-design`、`background-image`、`starry-background`、`bg-pulse`） | 非功能形态；可用 1–2 个静态 logo 替代 |
| MiMo worker/RPC 与 `--port` 双模 | trha 已有 HTTP/SSE + scheduler 架构，不重复造 |
| `tui-migrate` / `tui-schema` | trha 用 `settings.yaml` 分层配置，等价能力已有 |
| `win32.ts`（TUI 层 Windows 特化） | shell 语义已在 scheduler `shell.ts` 统一（M0–M2 of windows-shell-port-plan） |

### 执行顺序与推荐

依赖最少、收益最大的第一刀是 **M5 + M6**（纯外壳，不阻塞于后端）：
消息流形态（reasoning/step/compaction/retry/error/patch/structured/footer）
与工具特化渲染（17 → 8 组合并）+ 逐卡折叠。之后 M7（Home/Toast/导出/stash）、
M8（对话框；B 项单独排期）、M9（编辑器）、M10（侧栏）。

每个原子的验收沿用本仓纪律：纯模块 spec（`trha-cli-test`）+ 必要时 pty 人工验收；
B/C 项在 scheduler/内核侧先落端点与事件，再回填 UI（不做空壳）。

---

## 自检记录

- 覆盖度：分析文档 §5 判定表逐行有落点——硬伤→M0，简陋(输入/markdown/工具卡/token)→M1，缺失(对话框)→M2，(diff 审批)→M3，(侧栏/补全/leader/主题/鼠标)→M4，安全特例/真实中断/drain window→M3.5；**MiMo 全量形态面（203 文件清单逐项核对）→ M5–M10**（2026-10-25 重定范围，含依赖标注与不移植建议）。
- 占位符：无 TODO；M5–M10 每个原子都有 MiMo 对照、现状、依赖三列；需后端能力的项显式标 `B`/`C`，不以 UI 空壳充数。
- 类型一致：`applyChunk`/`PendingMsg`/`StreamChunk` 在任务 1 定义，任务 2/3 引用同名。
- **状态纪律（2026-10-25 新增）**：勾选以代码核对为准，不凭记忆；完成一项须写明落地证据（文件 + 行号或模块名），未做的不勾。
