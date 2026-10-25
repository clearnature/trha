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
| **M3.5 纠偏与收口**（新增） | 移除 drain window、双击 esc 修正、真实中断、审批安全特例、文档真实性、人工验收 | 下列 8 项逐条通过；文档勾选与代码一致 | **进行中（6/8，剩 reject 原因与人工验收）** |
| **M4 侧栏与高级** | 侧栏（token/成本/TODO）、@文件补全、leader 键、truecolor 主题、鼠标 | 侧栏 ≥80 列停靠、窄屏浮层；`@` 触发文件补全；主题含 truecolor 调色板 | 未开始，拆三刀 |
| **M5 存量补齐**（新增，不承诺） | fork/timeline/recovery、审批 diff 全屏、卡片焦点折叠、toast、reject 原因、成本/TPS | 每项启动时再细化 | backlog |

---

## 现状快照（2026-10-25 代码核对，非记忆）

| 里程碑 | 真实状态 | 证据 |
| --- | --- | --- |
| M0 | 流式渲染可用；drain window 已由终态等待替代（M3.5-1）；**人工验收仍未做**（3.3 勾选已回退）；spinner 实为内容驱动而非 Tick 驱动 | `Core.SSE.isTerminalPayload`、`Brick.hs` 的 `timeout 250000`、`:603-608` |
| M1 | 五项功能在；工具卡折叠只切"最近一张"，无卡片焦点 | `toggleRecentFold`（`Brick.hs`） |
| M2 | 对话框栈与 escape 表在；`resolveEscape` 实接线只喂 `efStack`（选区/shell/联想恒 False）；双击 esc 已按 Running 布防并在触发后清 armed（M3.5-2）；真实中断已接（M3.5-3） | `UI.Dialog.escWiring`、`Brick.hs` escape 段 |
| M3 | 审批链路（parked → 浮层三选 → decision）与 diff 分类上色在；审批是**居中浮层**而非计划原文的"底部审批条"；删除类命令已无 always（M3.5-4）；diff 行号与 120 列阈值已补（M3.5-8）；reject 仍不能附原因 | `UI.Dialog.approvalOptions`、`UI/Render/Diff.hs` |
| M4 | 未开始 | — |

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

  - [ ] 步骤 3.2：移除 `Brick.hs:953-961` 的 `threadDelay 100_000` drain window——以 `ChunkDone`/`SseMessage` 终态事件收尾（对齐 MiMo 的 step-finish 语义）。
    **未完成（2026-10-25 核对）**：代码已随文件增长漂到 `Brick.hs:1349-1351`，`threadDelay 100000` 与 "drain window" 注释仍在。转 M3.5-1。

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
- [ ] **diff 显示规格（未做）**：行号对齐与「宽 <120 用 unified」的显示规则。当前只有分类上色，没有行号、没有宽度阈值分支。转 M3.5-8。

## M3.5：纠偏与收口（新增，先于 M4）——**进行中（6/8）**

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
- [ ] **3.5-5 reject 附原因（需契约变更，启动时二选一）**：MiMo 的 reject 可填原因，当前 decision 端点只收 `{approve}`。
  方案 A（默认）：`POST /decision` 增可选 `reason`，内核把原因拼进 tool result 供模型见；三壳契约登记。
  方案 B：不做，把理由写进本节（若内核改动超过半天或会影响其他壳的语义）。
- [x] **3.5-6 文档真实性**：已回退 M0-3.2/3.3 的假勾选、登记 spinner 内容驱动偏差、把 M3 形态改为浮层并把 diff 拆成"已做/未做"两项；本轮随 3.5-1…4 同步勾选与证据。
- [ ] **3.5-7 人工验收清单（用户执行，回填本节）**：
  - [ ] `cabal run trha -- tui` 连真实模型：长回复逐字增长、无重复段落
  - [ ] 工具卡：`ctrl+o` / 空输入 `enter` 折叠展开，输出尾部预览正确
  - [ ] footer：in / out / total / ctx% 数值合理
  - [ ] 配一条 ask 规则：审批浮层弹出、消息流不可输入、once / always / reject 三路结果正确；always 后同命令不再询问
  - [ ] diff 输出有增删配色
- [x] **3.5-8 diff 显示规格**：行号对齐与宽度阈值。
  落地：`UI.Render.Diff` 增 `hunkStart`/`numberDiff`/`DiffRow`（旧/新行号分别推进：context 双增、删除只推旧、新增只推新；hunk 外的 meta 行不编号）、`diffLayout`/`renderDiffRow`（**<120 列 inline unified 无行号，≥120 列加 4+4 行号栏**）与 `looksLikeDiff`（以 hunk 头为准，避免把 `-` 列表误判成 diff）。工具卡展开态在 `looksLikeDiff` 时改走 `diffWidget`（渲染时取 `availWidthL` 定布局，逐行按 class 上色）。
  与 MiMo 的差异（已登记）：MiMo 在宽屏切 side-by-side，这里保持 unified 只加行号栏——工具卡展示的是输出尾部预览，配对 hunk 没有收益。
  测试：DiffSpec 新增 12 例（hunk 解析含无计数形式、编号推进、hunk 外不编号、阈值两侧、两种渲染、looksLikeDiff）。

## M4：侧栏与高级（拆三刀，逐刀可交付）

### M4-1 侧栏

- 宽度策略抽纯模块 `UI/Layout.hs`：≥80 列停靠 / 窄屏浮层（MiMo 参考 42 列 + `width>120` 规则；最终阈值实现时定并写进 spec）。
- 内容三节：Context（token/成本/占用%——复用 footer 已有的 `Usage`/`appCtxSize`）、TODO（数据源优先 `session.teamTasks`，无则空态）、会话信息（id/标题/模型）。
- 验收：≥80 列停靠、窄屏浮层可开合；布局策略 spec 覆盖两侧阈值；三节均无数据时不崩。

### M4-2 `@` 文件补全

- 纯模块 `UI/Completion.hs`：cwd 递归索引（忽略 `.git`/`node_modules`/`dist-newstyle`，限深度与条目数）、查询过滤、选中后展开为路径文本。
- 交互：输入 `@` 触发浮层（复用 `DialogStack` 或独立 popup），Enter 插入路径（无 extmark）。
- 验收：`@` 弹层 + 过滤 + 插入；纯模块 spec；大仓下首次索引不阻塞输入（索引异步、结果回灌）。

### M4-3 主题 / leader / 鼠标

- truecolor 调色板：`Theme` 解析扩展到 RGB，保留 dark/light 两套预设；brick/vty 侧用 `Graphics.Vty.Attributes` 的 RGB color。
- leader 键：先列键位表（避免与 `ctrl+o`、esc、`/`、`ctrl+p` 冲突），再做自定义 modifier 链，键表 spec 化。
- 鼠标滚动：`EvMouse` → 消息区 viewport 滚动。
- 验收：主题切换可见且两套预设完整；leader 表 spec 逐条；滚轮滚动消息区。

## M5：存量补齐（新增，不承诺，启动时逐个细化）

分析文档 §5 里仍判"简陋/缺失"但不在 M0–M4 承诺内的项，登记备查：

- 会话管理：fork / timeline / recovery（当前只有列表 + resume 回放）
- 审批 diff 全屏（MiMo `ctrl+f` Portal）与审批期间 diff 查阅
- 逐卡折叠（卡片焦点/命中测试）替代"最近一张"
- Toast 通知、成本/TPS 统计（footer 目前只有 token）
- reject 原因（若 M3.5-5 选 B）
- i18n 扩到多 locale（当前 zh/en）

---

## 自检记录

- 覆盖度：分析文档 §5 判定表逐行有落点——硬伤→M0，简陋(输入/markdown/工具卡/token)→M1，缺失(对话框)→M2，(diff 审批)→M3，(侧栏/补全/leader/主题/鼠标)→M4，安全特例/真实中断/drain window→M3.5，会话管理与成本/TPS 等剩余「简陋」项→M5 backlog。
- 占位符：无 TODO；M4/M5 为显式的「启动时细化」范围声明。唯一决策点：M3.5-5（reject 原因）给出 A/B 两条路径与默认值，不阻塞其余排期。
- 类型一致：`applyChunk`/`PendingMsg`/`StreamChunk` 在任务 1 定义，任务 2/3 引用同名。
- **状态纪律（2026-10-25 新增）**：勾选以代码核对为准，不凭记忆；完成一项须写明落地证据（文件 + 行号或模块名），未做的不勾。
