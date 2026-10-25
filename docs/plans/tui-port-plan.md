# TUI 移植计划：MiMo-Code 形态 → trha CLI

> 事实输入：[`../reference/mimocode-tui-analysis.md`](../reference/mimocode-tui-analysis.md)（五路源码直读，交叉验证完成）。
> 执行方式：subagent-driven-development 或 executing-plans。步骤用 `- [ ]` 语法。
> **范围声明**：M0 在本计划内给出完整 TDD 任务（可直接执行）；M1–M4 是里程碑契约（验收标准 + 文件结构），每个启动时按本仓库惯例另行细化为独立 TDD 计划——这是 writing-plans 的「跨子系统拆独立计划」规则，不是占位符。

**目标：** 把 trha 的 TUI 从「单文件 1360 行的简陋消息流」升级为 MiMo-Code 形态的终端工作台——真实流式、对话框化、可折叠工具渲染、有成本与上下文可见性。
**架构：** 保留 trha 分层（UI/Bridge/Core）与「纯视图模型 + spec」测试惯例；移植单元是**交互契约与组件形态**（MiMo 是 TS/Solid + opentui，trha 是 Haskell/brick，代码不可搬）。第一阶段先修数据流地基（SSE delta 丢弃是当前硬伤），随后按「对话框系统 → 审批/diff → 侧栏与高级」逐里程碑推进，每个里程碑产出可工作可测试的软件。
**技术栈：** Haskell + brick（现状不变）；新增模块沿 `packages/app/CLI/UI/` 既有目录约定。

---

## 里程碑总览与验收标准

| 里程碑 | 内容 | 验收标准 |
| --- | --- | --- |
| **M0 数据流地基** | 消费 SSE text delta、流式渲染、去除 drain-window hack | 对真实 scheduler 发消息：回复**逐 delta 增长**（非整段出现）；无重复渲染；spec 全绿 |
| **M1 核心形态** | 多行输入、markdown 增强、工具卡折叠、token/上下文统计、会话状态 spinner | 输入 1-6 行自适应；markdown 列表/标题/行内样式可见；工具卡可 `enter` 折叠展开；footer 显示 prompt/completion/累计/占用% |
| **M2 对话框系统** | UI/Dialog.hs 栈 + escape 层级表；模型/会话/命令面板迁入对话框 | dialog 栈 LIFO + escape 语义表逐条通过；`/models`、`/sessions`、`ctrl+p` 均为浮层，消息流不再被文本列表污染 |
| **M3 审批与 diff** | 权限审批对话框 + unified diff 渲染 + once/always/reject | 审批到达时消息流锁定；diff 正确配色；once/always/reject 走 scheduler `decision` API |
| **M4 侧栏与高级** | 侧栏（token/成本/TODO）、@文件补全、leader 键、truecolor 主题、鼠标 | 侧栏 ≥80 列停靠、窄屏浮层；`@` 触发文件补全；主题含 truecolor 调色板 |

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

  - [x] 步骤 3.2：移除 `Brick.hs:953-961` 的 `threadDelay 100_000` drain window——以 `ChunkDone`/`SseMessage` 终态事件收尾（对齐 MiMo 的 step-finish 语义）。

  - [x] 步骤 3.3：手动验收（对真实 scheduler）：发一条长回复，确认逐字增长、无重复段落（若 `/api/agent/step` 整段 reply 与 SSE delta 重复，以 delta 流为准、step 返回仅作 finalize 信号——在 Scheduler.hs 注释记录该契约）。`git commit -m "feat(cli): streaming reply rendering with spinner"`。

## M1：核心形态（启动时细化，契约如下）——**已完成（2026-10-25）**

> 进度：五项全部落地（spec 256/256）：多行输入与共享历史（`UI/InputHistory.hs`）、markdown 增强（`spanWrap` 替代被 3.0 删除的 widget 级 `wrap`）、工具卡折叠（结构化 `ToolCard` + 内核 `output` 尾部预览，契约 §3 已登记）、token 统计（内核 `usage` 回显 + footer 四段 + 会话索引累计）、spinner 三态（`RunState` 阶梯）。提交 f7a5b82/014fe87/9e4b7c3/f1d2907/0f72c61/8661bff。**待人工验收**：`cabal run trha -- tui` 连真实模型。

- [x] **多行输入**：brick editor `Just 1 → 动态高度`，1-6 行自适应（对齐 MiMo `maxHeight=6`）；`alt+enter` 换行、enter 提交；光标在首行时 ↑ 翻输入历史（复用 REPL 历史文件）。
  落地：editor 限 6 行（brick line-limit 同时是编辑上限与显示上限，`vLimit` 天然自适应）；alt+enter 直投 `handleEditorEvent`（brick 只对纯 `KEnter []` 换行）；↑/↓ 在首/末行翻历史，新增纯模块 `UI/InputHistory.hs`（草稿暂存 + `~/.trha/history` 共享读写，多行条目以换行→反斜杠 n 转义存行）。
- [x] **markdown 增强**：`UI/Render/Markdown.hs` 增列表/标题/行内样式渲染（bold/code 现已解析、只差渲染），纯函数 + spec。
  落地：`MdHeading`/`MdListItem` 解析 + `renderBlocks` 按 span 属性渲染；brick 3.0 **删除了 widget 级 `wrap`**，新增渲染时 `spanWrap`（镜像 `txtWrapWith` 技法：context 宽度 + 渲染时重排，宽字符经 vty wcwidth 计宽，超宽词按字符硬切）。
- [x] **工具卡折叠**：`UI/Render/ToolCard.hs` 增加 collapsed/expanded 两态 + 输出内容行；`AppEvent` 增 toggle 消息；状态存 Map 消息 id。
  落地：`msgTool` 升级为结构化 `ToolCard`（名/参/状态/时长/输出预览）；`msgId`（位置式）与 `appFolds :: Map Int ToolFold`；`ctrl+o` 或空输入 `enter` 切换最近工具卡；内核 tool:update 增 `output` 尾部预览（末 12 行 ≤2KiB，可选字段，已登记 `docs/contracts/protocol-shell-kernel.md` §3 并过 TypesSpec roundtrip + scheduler 受影响 specs）。
- [x] **token/上下文统计**：`Core/Types.hs` 的 `Usage` 已有 prompt/completion——footer 增 `in/out/累计/占用%` 四段；累计值入 `Core/Transcript.hs` 会话索引。
  落地：内核 agent/step 响应补 `usage` 回显（promptTokens=in；本轮 completion/cacheHit/cacheMiss 增量；cumulativeTokens=session 累计）；Bridge 增 `sendMessageWithUsage`（旧签名保留）；TUI `appUsage`/`appCtxSize`（启动异步拉 /api/models）；footer 新 metric key `usage`（默认启用，En/Zh 各四段，无 echo 时留空）。
- **会话状态 spinner**：idle/awaiting-approval/running 三态显示（为 M3 审批锁定做状态地基）。

## M2：对话框系统（启动时细化，契约如下）

> 前置已就绪（2026-10-25）：CLI 已升级 **brick 3.0**（`trha-cli.cabal` 钉 `brick >= 3.0`）——3.0 自带层嵌入组合子 `above` 与 `Brick.Widgets.Menu/MenuBar` 弹出菜单，且鼠标点击不再穿透高层遮罩，对话框/浮层直接受益。参考源码已收录 `3rdparty/brick-3.0/`（注意：3.0 删除了 widget 级 `wrap`，M1-2 以渲染时 `spanWrap` 补位）。

- [x] 新模块 `UI/Dialog.hs`：`DialogStack = [Dialog]`、`stackPush/stackPop/stackTop/stackNull`、**escape 层级表** `resolveEscape`（对齐 MiMo：选区→弹栈→shell→联想→审批；5 秒双击布防 `escPress`——真实中断接 M3 审批锁定）。（2026-10-25 完成，spec 逐条覆盖，278/278）
- [x] 迁移三个既有文本交互进对话框：模型选择器（`/models` 推空栈 + `EvModels` 异步填充）、会话列表（`/sessions`/`EvSessions` 走本地 `SessionSummary`，含标题与累计 token）、命令面板（现有 picker 改浮层，键位对齐 `ctrl+p` + `/`；`PickerState` 已删除）。绘制用 brick 层列表：`drawUI` 首元素 = 顶层，`centerLayer` 居中卡片。（2026-10-25 完成）
- 验收：`escape` 层级表逐条 spec 化（纯状态机测试，不需要渲染）——✅ `UI/DialogSpec.hs`（层级表 5 行 + 双击布防 3 行 + 栈/选择/命令编辑 11 例）。

## M3：审批与 diff（启动时细化，契约如下）

- 权限审批对话框：到达审批请求时消息流锁定、底部审批条（对齐 MiMo once/always/reject 三选 + always 二次确认）；走 scheduler `POST /api/session/:id/decision`（Bridge 已有）。
- `UI/Render/Diff.hs`：unified diff 解析 + added/removed 配色（纯函数 + spec，行号对齐 MiMo `<diff>` 行为：宽 <120 unified）。

## M4：侧栏与高级（启动时细化，契约如下）

- 侧栏：≥80 列停靠 / 窄屏浮层（对齐 MiMo 42 列 + `width>120` 规则），内容三节：Context（token/成本/占用%）、TODO、会话信息。
- `@` 文件补全（cwd 递归 + 过滤；无 extmark，降级为「选中后展开为路径文本」）。
- leader 键（brick 自定义 modifier 链）、主题 truecolor 扩容（brick 支持 truecolor attr）、vty 鼠标事件（滚动）。

---

## 自检记录

- 覆盖度：分析文档 §5 判定表逐行有落点——硬伤→M0，简陋(输入/markdown/工具卡/token)→M1，缺失(对话框)→M2，(diff 审批)→M3，(侧栏/补全/leader/主题/鼠标)→M4；「无」项中会话管理增强并入 M2 会话对话框。
- 占位符：无 TODO/待定；M1–M4 为显式的「另行细化」范围声明（writing-plans 跨子系统拆分规则）。
- 类型一致：`applyChunk`/`PendingMsg`/`StreamChunk` 在任务 1 定义，任务 2/3 引用同名。
