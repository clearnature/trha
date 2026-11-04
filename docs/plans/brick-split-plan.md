# Brick.hs 按功能拆分计划

> 基线：`main = 237d487`（`UI.Brick` 4333 行 / 151 个顶层定义）。
> 行号均以该提交为准；每批执行后行号会漂移，以**函数名**定位而不是行号。
> 权威结构文档见 [`docs/architecture/architecture.md`](../architecture/architecture.md)；
> 平台差异见 [`docs/reference/windows-dev-notes.md`](../reference/windows-dev-notes.md)。

## 1. 为什么要拆

`packages/app/CLI/UI/Brick.hs` 曾长到 **4333 行、151 个顶层定义**（拆分前基线；2026-11-04
已降至 3313 行），把五类职责挤在一个模块里：

| 职责 | 代表定义 | 数量 |
|---|---|---|
| 装配/入口 | `initialState`、`appFor`、`runTUI`、`themeAttrMap` | ~8 |
| 渲染 | `draw*` | 15 |
| 交互 | `handle*` | 13 |
| 命令 | `handleSlash`（**实测 861 行 / 41 个命令**，原估「90+ 分支」偏高） | 4 |
| 状态查询/纯辅助 | `msgHeight`、`cardHidden`、`sidebarDataFor`… | ~110 |

后果不是「文件长」这种审美问题，而是三条实际障碍：

1. **无法单测**：`EventM ResourceName AppState` 与 Brick 运行时绑定，任何 `handle*`
   都只能在真终端里验证。
2. **改一处要读全篇**：`drawStatus` 的 15 个 segment 与 `handleSlash` 的 861 行
   同处一文件，定位成本高。
3. **合并冲突面大**：任何两人同时改 TUI 都命中同一文件。

## 2. 拆分原则

### 2.1 依赖方向（单向，禁止回指）

```
纯函数层   UI.Render.Spans / UI.Render.*      无 EventM、无 Widget
   ↓
文本层     UI.Brick.Draw.Status                AppState → Text
   ↓
渲染层     UI.Brick.Draw.{Status,Sidebar,Messages,Dialog}
   ↓
交互层     UI.Brick.Keys                       Event → EventM
   ↓
命令层     UI.Brick.Slash                      Text → EventM
   ↓
装配       UI.Brick（薄壳：initialState/appFor/runTUI）
```

**规则**：下层不得 import 上层。发现需要回指时，说明边界划错了，应把共享部分下沉，
而不是加 import。

### 2.2 平台兼容约束（硬性）

依据 [`windows-dev-notes.md`](../reference/windows-dev-notes.md)：

1. **不得引入无条件平台假设**。现有平台分支都在 `#ifdef mingw32_HOST_OS` 或运行时
   `bcPlatform` 判定内，拆分后必须保持这个性质。
2. **列宽计算必须继续复用** `UI.TextWidth`（`takeCells` / `textWidth`）与
   `UI.Render.Spans`（`splitAtWidth` / `fillLines`）。文档 §5 记录 Reasonix 的
   `glyphFit`（GDI 字形探测 + ASCII 降级）**未移植**，因此列宽是唯一依据；
   各模块自行计算会在 conhost/936 下产生不一致的错位。
3. **不新增平台分支**。拆分是纯搬运，任何「顺手修 Windows 行为」都另开提交。

### 2.3 拆分纪律

- 一次只搬**一组同职责函数**，搬完立即 `cabal build all` + `cabal test trha-cli-test`。
- **禁止 `sed` 改代码**（AGENTS.md）：用 `edit_file` 做精确替换。
- 大于 100 行的连续函数块（如 `drawStatus` 184 行）要**分段删除**，每段重读偏移量，
  不要一次 `old_string` 贴 184 行。
- 迁移时**逐分支核对**，不要凭记忆重写。已发生两次事故：`diffAttrOf` 漏掉
  `CPlain -> "tool"`、`roleStyle` 被误删——都是靠编译报错才捞回。

## 3. 现状（批次 0–3 完成，批次 4 部分完成）

| 批次 | 提交 | 模块 | 迁出内容 |
|---|---|---|---|
| 0-a | `65d53b7` | `UI.Render.Spans` | `SpanTok(..)`、`spanToks`、`spanToksWith`、`fillLines`、`splitAtWidth`、`truncLine`、`diffAttrOf`、`spinnerFrame`、`boolText`、`isCompactionMark` |
| 0-b | `237d487` | `UI.Brick.Draw.Status` | `modelLabel`、`statusLine`、`pricesOf` |
| 1 | 多个 | `UI.Brick.Draw.Status`（续） | 13 个 `status*` 纯函数（`statusLine`/`statusModelLine`/`statusGitLine`/`statusStatsLine`/`statusSandboxTag`/`statusClock`/`statusPeak`/`statusCtxPct`/`statusTurnsSuffix` …） |
| 2 | 多个 | `UI.Brick.Draw.Sidebar`<br>`UI.Brick.Draw.Dialog`<br>`UI.Brick.Draw.Settings`<br>`UI.Render.Settings` | `drawSidebar`、`drawCompletion`、`sidebarDataFor`；`drawDialog`、`dialogRows`、`dialogRow`、`dialogCountdown`、`dialogApprovalLabel`、`dialogConfirmLabel`、`drawPalette`、`drawWizard`、`wizardSummary`；`drawSettingsPanel`、`settingsRows`、`visibleRows`、`settingsListMax`；`renderStatusRows`、`computeStatsBlocks`、`renderStatsBlocks` |
| 3 | `fc12937` `a0633b3`<br>`1755d7d` `09808dd` | `UI.Brick.Draw.Messages`<br>`UI.Brick.Draw.Status`（`drawStatus`） | `drawMessage`、`drawMessages`、`drawPending`、`drawInput`、`drawPlanCard`、`drawHome`、`drawUI`、`drawToast`、`cardHidden`、`roleStyle`、`messageHeader`、`messageBody`、`renderToolBody`、`renderBlocks`、`spanWrap`、`diffWidget`；`drawStatus` |
| 4（部分） | `cdb7909` `6e1aaa5`<br>`bd85b22` `a8337a4`<br>`7cc3527` `3bb87d6` | `UI.Brick.Input`<br>`UI.Brick.DialogKeys`<br>`UI.Brick.Toast`<br>`UI.Brick.Apply` | `promptIsEmpty`、`editorValue`、`editorCursor`、`alwaysConfirmText`；`dialogAppend`、`dialogDelete`、`withCommands`、`modifyTop`、`scrollBottom`、`persistSelection`、`chooseProvider`；`showToast`；`applyLanguage`、`applyTheme` |

**行数轨迹**：4414 → **3313**（-1101，-24.9%）
**测试基线**：667 → **685 examples, 0 failures**（批次 3 新增 18 例）

> 批次 3 的教训见 [`docs/reference/brick-split-incident-2026-11-04.md`](../reference/brick-split-incident-2026-11-04.md)：
> 一次「删一半就编译」的中间态让工作区不可编译数小时，且无人发现。此后每步都必须
> 以「编译通过 + 测试全绿 + 已推送」结束。

---

## 4. 四批边界总表

| 批 | 模块 | 迁出函数（基线行号） | 新增依赖 | 验证点 |
|---|---|---|---|---|
| **1** | `UI.Brick.Draw.Status`（续） | `drawStatus`(1235, 184行) | `UI.Render.Footer`、`UI.TextWidth`、`UI.TimeStamp`、`Core.TurnStats`、`Core.Types` | 状态栏 15 段渲染一致 |
| **2** | `UI.Brick.Draw.Sidebar`<br>`UI.Brick.Draw.Dialog` | `drawSidebar`(479)、`sidebarDataFor`、`drawPalette`(496)、`drawWizard`(526)、`wizardSummary`、`drawCompletion`(549)、`drawDialog`(586-896)、`drawSettingsPanel`(3973) | `UI.Render.Sidebar`、`UI.Render.Picker`、`UI.Dialog`、`UI.SettingsPanel` | 每个对话框能打开且内容正确 |
| **3** | `UI.Brick.Draw.Messages` | `drawUI`(374)、`drawToast`(436)、`drawHome`(445)、`drawMessages`(897)、`drawMessage`(1064)、`drawPending`(1161)、`drawInput`(1170)、`drawPlanCard`(1204)、`cardHidden`、`msgHeight`、`roleStyle`、`messageHeader`、`messageBody`、`renderToolBody`、`renderBlocks`、`spanWrap`、`diffWidget` | `UI.Render.{Markdown,ToolCard,Message,Diff,FilePart}`、`UI.Render.Spans` | 长会话渲染、工具卡折叠、markdown 代码块 |
| **4** | `UI.Brick.Keys` | `handleEvent`(1517)、`handleLeaderKey`(1605)、`handleCtrlCKey`(1627)、`handleCtrlDKey`(1643)、`handleDialogKey`(1748)、`handleChatKey`(1950)、`handleChatEnter`(2070)、`handleAppEvent`(2681)、`handleSettingsKey`(3853)、选区相关（`msgRowAt`/`inSel`/`finishSel`/`extendSel`/`copySelectionText`） | `UI.State`、`UI.Dialog`、`UI.Selection`、`Core.Clipboard`、`Bridge.Scheduler` | 键位矩阵（见 §5.4） |
| **5** | `UI.Brick.Slash` | `handleSubmit`(3094)、`handleSlash`(3130-3632, 90+分支)、`handleChat`(3633)、`handleChatWith`(3674) | `UI.Commands`、`Bridge.Scheduler` | 命令矩阵（见 §5.5） |

保留在 `UI.Brick` 的只剩装配层：`sandboxOn`、`initialState`、`appFor`、`themeAttrMap`、
`toVtyAttr`、`toVtyStyle`、`vtyFg`、`runTUI`。

---

## 5. 每批详细说明

### 批次 1：状态栏完整（`drawStatus`）

**为什么单独一批**：184 行里塞了 15 个 segment 计算（`ctxSeg`、`compactSeg`、`tpsSeg`、
`tokensSeg`、`usageSeg`、`costSessionSeg`、`costTurnSeg`、`outSeg`、`cacheTokensSeg`、
`sessTokensSeg`、`balanceSeg`、`peak`、`cacheSeg`、`modelLine`、`gitLine`），全是
`AppState → Text` 的纯映射，本该可单测。

**第一步（低风险）**：先把这 15 个 segment 提为**顶层纯函数**留在 `Brick.hs`，
`drawStatus` 改为调用；编译 + 测试。此时行为零变化。

**第二步**：把提好的 segment 与 `drawStatus` 一并迁到 `UI.Brick.Draw.Status`。

**依赖清单**（新增 import）：
- `UI.Render.Footer`：`footerMetrics`、`statusFitsOneRow`、`wrapStatusLine`、`parseMetrics`、`branchFromHead`
- `UI.TextWidth`：`takeCells`
- `UI.TimeStamp`：`clockWithZone`
- `Core.TurnStats`：`Prices`、`hasPrices`、`isOffPeak`
- `Core.Types`：`balanceCurrency`、`balanceTotal`、`usageTotalTokens`、`usagePromptTokens`、`usageCompletionTokens`、`configMetrics`
- `UI.I18n`：`tr`

**验证点**：
1. `cabal build all` = 0，`cabal test trha-cli-test` 667 例全绿
2. tmux 实测（`-x 80` 与 `-x 140` 两种宽度）：
   - 第 1 行：模式标签 · `appStatus` · 时钟 · 沙箱徽标 · 模型名
   - 第 2 行：`目录@分支` · git stat · 各统计段 · 余额
   - 80 列下不溢出（`statusFitsOneRow`/`wrapStatusLine` 生效）

**回滚**：单提交，`git revert` 即恢复。

### 批次 2：侧栏与对话框

**迁出**：`drawSidebar`、`sidebarDataFor`、`drawPalette`、`drawWizard`、`wizardSummary`、
`drawCompletion`、`drawDialog`（310 行，最大的一块）、`drawSettingsPanel`。

**建议再拆两步**：
1. `UI.Brick.Draw.Dialog`：`drawDialog` + `drawPalette` + `drawWizard` + `drawSettingsPanel`
2. `UI.Brick.Draw.Sidebar`：`drawSidebar` + `sidebarDataFor` + `drawCompletion`

**依赖**：`UI.Render.Sidebar`（`sidebarLines`/`sidebarHint`）、`UI.Render.Picker`、
`UI.Dialog`（`Dialog` 构造子、`filterModels`/`filterSessions`/`dialogCommandsInitialSel`）、
`UI.SettingsPanel`。

**验证点**：
1. 编译 + 667 例
2. tmux 逐个打开：`/models`、`/sessions`、`/theme`、`/language`、`/sandbox`、`/settings`、
   `/provider`、`/switch`、`/agents`、`/skills`、`/stash`、`/help`
3. 对话框查询行过滤（`/models` 输入 `v4` 只剩 `deepseek-v4-pro`）
4. `j/k` 在无查询行列表生效、在有查询行列表不生效（`0f1d1b2` 的行为）

**风险**：`drawDialog` 310 行、分支最多（十余种 `Dialog` 构造子）。必须分两步：
先搬 3 个小的，编译通过后再搬 `drawDialog`。

### 批次 3：消息区渲染

**迁出**：`drawUI`、`drawToast`、`drawHome`、`drawMessages`、`drawMessage`、`drawPending`、
`drawInput`、`drawPlanCard`，以及消息区的纯辅助：`cardHidden`、`msgHeight`、`roleStyle`、
`messageHeader`、`messageBody`、`renderToolBody`、`renderBlocks`、`spanWrap`、`diffWidget`。

**依赖**：`UI.Render.Markdown`、`UI.Render.ToolCard`、`UI.Render.Message`、
`UI.Render.Diff`、`UI.Render.FilePart`，以及已迁出的 `UI.Render.Spans`。

**验证点**：
1. 编译 + 667 例
2. tmux 长会话实测：
   - markdown 代码块（带 lang 标签）+ 表格
   - 工具卡展开/折叠（`Ctrl+O`）前后行数变化
   - 焦点标记 `▶` 只落在**工具卡**上（`e2551e3` 修复的行为）
   - `Alt+↑/↓` 焦点移动
   - 长粘贴折叠 `[Pasted text #N · X lines]`

**风险**：`drawUI` 是总入口，搬运后 `Brick.hs` 的 `appFor` 需要 import；注意
`drawUI` 里对 `RouteHome`/`RouteSession` 的分派不要改结构。

### 批次 4：交互层

**已完成（2026-11-04）**：`UI.Brick.Input`、`UI.Brick.DialogKeys`、`UI.Brick.Toast`、
`UI.Brick.Apply`——共 15 个函数、约 250 行（详见 §3）。

**待迁出**：`handleEvent`(709)、`handleLeaderKey`(797)、`handleCtrlCKey`(819)、
`handleCtrlDKey`(835)、`handleDialogKey`(935)、`dialogActivate`(982)、`handleChatKey`(1095)、
`handleChatEnter`(1215)、`handleAppEvent`(1805)、命令面板组（`refreshCompletion`(1251)、
`paletteItemsFor`(1259)、`allPickerItems`(1284)、`refreshPalette`(1298)、`movePalette`(1318)、
`runPaletteItem`(1323)）、中断审批组（`requestInterrupt`(844)、`requestStopServices`(856)、
`stopServicesAndHalt`(867)、`decideApprovalNow`(880)、`escapeHierarchy`(905)、
`escapeWithoutApproval`(911)）、选区组（`msgIndexAt`(629)、`msgHeight`(636)、`msgRowAt`(647)、
`beginSel`(655)、`extendSel`(662)、`copySelectionText`(672)、`finishSel`(689)、
`toolCardIds`(1680)、`moveCardFocus`(1684)、`toggleFocusedCard`(1694)）。

**依赖关系（2026-11-04 实测，取代此前的猜测）**

`rg 'dialogActivate'` 在 `UI.Brick.hs` 里只有 4 处；`handleSlash`（2254–3114，861 行）
内部只调用 `modeAction`(3 次) / `handleSlash`(2 次，内部子分派) / `resumeSession`(1 次)，
**不调用任何 `handle*`、也不调用 `dialogActivate`**。

=> **不存在循环依赖。** 真实依赖是单向 DAG：

```
handleEvent (709)
 ├→ handleLeaderKey / handleCtrlCKey / handleCtrlDKey
 ├→ handleDialogKey (935) → dialogActivate (982) ─┐
 ├→ handleChatKey (1095)                         ├→ handleSlash (2254-3114)
 ├→ handleChatEnter (1215) ──────────────────────┘     → modeAction / resumeSession
 ├→ handleAppEvent (1805)
 └→ 选区：msgRowAt / beginSel / extendSel / finishSel
```

> **一次误判的记录**：上一轮仅凭 `dialogActivate → handleSlash` 这条单向边，臆测存在
> 反向边，据此得出「强连通环、必须回调注入或整体搬迁」的结论。实际 `rg` 统计推翻了它。
> **教训：判断循环依赖必须全文件统计调用点，不能凭印象补边。**

**因此执行顺序**：`handleSlash`（批次 5）先于 `dialogActivate`（它会调 `handleSlash`）；
其余子组（选区、中断审批、命令面板）可按任意顺序，`handleEvent` 最后。

**为什么选区跟着交互层**：它们都是 `EventM` 里的鼠标/键盘行为，与渲染无关。但注意
`inSelRange`/`cardHidden` 被渲染层调用——`inSelRange` 已下沉到 `UI.Selection`（纯函数），
`cardHidden` 在 `UI.Brick.Draw.Messages`。**批次 3 必须先于批次 4**，否则产生回指。

**依赖**：`UI.State`、`UI.Dialog`、`UI.Selection`、`Core.Clipboard`、`Bridge.Scheduler`、
`UI.Event`（`AppEvent`）、以及本批次已迁出的四个新模块。

**验证点**（tmux 键位矩阵）：

| 键 | 期望 |
|---|---|
| `Ctrl+C`（有选区） | 复制、清空、不 arm |
| `Ctrl+C`（无选区）×2 | 第 2 次退出，状态栏先显示「再按一次 Ctrl+C 退出」 |
| `Ctrl+D` ×2 | 退出 |
| `Ctrl+L` | 清屏 |
| `Ctrl+S` | 提交 |
| `Ctrl+G` | 展开折叠的粘贴 |
| `Ctrl+O` | 折叠/展开工具卡 |
| `Alt+V` | 从剪贴板粘贴 |
| `Alt+↑/↓` | 工具卡焦点移动 |
| `Shift+Tab` / `Ctrl+Y` | 权限姿态循环（且真的改到服务端，见 `603a1cc`） |
| `Tab`（对话框内） | 选中项前进 |
| 鼠标拖选 + 松开 | 高亮保留、剪贴板写入 |
| `j`/`k`（无查询行列表） | 上下移动 |

**风险**：`handleChatEnter`/`handleChatKey` 与命令层耦合（回车既可能发消息也可能执行命令）。
搬运时保持**判定顺序**：斜杠命令 → 补全 → 普通消息，不要重排。

### 批次 5：命令层

**迁出**：`handleSubmit`(2218)、`handleSlash`(**2254–3114，861 行**)、`runShellCommand`(2239)、
`handleChat`、`handleChatWith`。

**实测数据（2026-11-04，取代此前的「90+ 分支」估计）**：

| 项 | 实测值 |
|---|---|
| `handleSlash` 行数 | **861 行**（2254–3114） |
| 其中的字面 `"/xxx"` 分支 | **28** 个 |
| 覆盖的命令名（含守卫分支去重） | **41** 个 |
| 它调用的本文件函数 | `modeAction`×3、`handleSlash`×2、`resumeSession`×1 |

**依赖**：`UI.Commands`（`executeCommand`）、`UI.Commands.Registry`（`parseCommand`）、
`Bridge.Scheduler`（数十个 HTTP 调用）、`modeAction`、`resumeSession`。

> 注意：`handleSlash` 与 `dialogActivate` 是**单向**关系（`dialogActivate → handleSlash`），
> 反向不存在。所以批次 5 应当**先于**批次 4 中的 `dialogActivate` 完成。

**验证点**（命令矩阵，见 [`docs/reference/cli-command-matrix.md`](../reference/cli-command-matrix.md)）：

1. 编译 + **685 例**
2. tmux 逐个执行命令矩阵里的条目，记录 `OK` / `DIALOG` / `FAIL`
3. 重点回归已修过的：
   - `/switch` 无参 → 打开可选中对话框（`d3a1e7c`）
   - `/provider` → `DialogProviders`
   - `/recap` `/btw` `/review` → 返回真实摘要（`4835673`）
   - `/skip` `/reject` `/abandon` 无计划时提示「No pending plan …」（`ee7b365`）
   - `/mode <x>` 带参数走 `modeAction`（`7f34bb8`）

**风险**：`handleSlash` 861 行，分支之间**顺序敏感**（`_ | cmd == …` 守卫分支必须在
字面分支之后的正确位置）。搬运**只做剪切**，不改分支顺序、不改守卫条件。

### 批次 5b：命令定义单一来源（建议，优先级高于继续拆模块）

**问题（2026-11-04 实测）**：命令在三个地方各定义一份，规模互不相等。

| 位置 | 规模 | 用途 |
|---|---:|---|
| `UI.Commands.Registry.slashRegistry` | **89** 条 `SlashCommand` | 补全 / 帮助（纯元数据，可单测） |
| `UI.Brick.handleSlash` | **41** 个命令 | TUI 执行分派 |
| `UI.Commands.executeCommand` | **106** 个分支 | 通用执行（REPL/TUI 共用） |

三个集合没有任何机制保证一致。**实证后果**：`/provider` 在 `handleSlash` 有分支
（应打开 `DialogProviders`），实测却走了 `executeCommand` 打印文本——因为两者都在，
而判定顺序只走了一条。

**对照 Reasonix**：`internal/frontend/cli/slash_registry.go` 的 `builtinSlashSpecs`
把 `{name, aliases, handler, help}` **绑定在同一张表里**——表即执行，元数据与行为
不可能漂移。加一个命令只改一处。

**方案对比**：

| 方案 | 做法 | 取舍 |
|---|---|---|
| A（Reasonix 式） | `SlashSpec { name, help, handler }` 合一 | 单一来源；但 `Registry` 被迫依赖 brick，失去纯层可测性 |
| **B（推荐）** | 纯元数据表 + 执行表 + **一致性测试** | 保持纯层可测；漂移由测试拦截 |
| C | 现状不动，只补测试 | 最小改动；106/41/89 的差距仍在，但不再静默 |

**方案 B 的落地形态**：

```haskell
-- UI.Commands.Registry（纯层，可测）
slashRegistry :: [SlashCommand]        -- 元数据 89 条

-- 执行表（可依赖 brick）
slashHandlers :: [(Text, Handler)]     -- Handler = [Text] -> EventM ResourceName AppState ()

-- test/ 里的一致性断言
it "元数据表与执行表的键集合相等" $
  sort (map scName slashRegistry) `shouldBe` sort (map fst slashHandlers)
```

这条测试一旦存在，`/provider` 那类「声明了却没接上」的问题会在 CI 暴露，
而不是靠人工 tmux 实测发现。

**债务的真实规模（2026-11-04 实测）**：新增一条命令要同步 **6 处**，其中 5 处已有
测试或明确兜底，第 6 处是有意保留的差异：

| # | 派生表 | 作用 | 防线 |
|---|---|---|---|
| 1 | `slashRegistry` | 声明（补全 / 帮助） | ✅ `RegistrySpec`·注册表→可解析（`3f86963`） |
| 2 | `parseCommandBase` | 文本 → `Command` | ✅ 同上（不落 `Unknown`） |
| 3 | `commandGroupOf` | 分到 GSession / GModel / … | ✅ 已有「lists every command exactly once」 |
| 4 | `UI.Interaction.layerTable` | 分到 CmdReply / CmdDialog / … | ✅ 已有「classifies every registered command (no fall-through)」 |
| 5 | `handleSlash`（TUI） | TUI 执行 | ✅ `RegistrySpec`·无孤儿命令（`17fd6a7`） |
| 6 | `executeCommand`（REPL） | REPL 执行 | ⚠️ 有意保留：兜底返回「Command not available in this front-end: \<构造子\>」，不是静默 |

**已知例外（必须登记，不可静默放过）**：`/ctx` 与 `/effort` 只在第 5 处有实现——
第 2 处会解析成 `Unknown`，第 6 处没有路径。补齐需要给 `Command` 加构造子并在
`executeCommand` 里实现同等逻辑（约 80 行），属独立一步。已在 `RegistrySpec` 的
`knownOrphans` 里显式列出，并写明「新增例外必须登记原因」。

**建议顺序**：先做 5b（约 20 行测试 + 补齐差异），再搬 `handleSlash`（否则搬完 861 行
case 仍要重写成表驱动，等于做两遍）。

---

## 6. 执行顺序与依赖关系

**已完成部分（批次 0–3）**

```
批次 0-a（纯函数层）──┐
批次 0-b / 1（状态栏）┼→ 批次 2（侧栏/对话框/设置）→ 批次 3（消息区）→ 批次 4（部分）
```

**剩余部分的真实依赖方向（2026-11-04 实测）**

```
批次 5b（命令单一来源 + 一致性测试）   ← 建议最先做
       ↓
批次 5：handleSlash（861 行）
       ↓ 被它调用
批次 4 剩余：dialogActivate → handleDialogKey
                            dialogActivate → chooseProvider（已迁）
批次 4 其余：选区组 / 中断审批组 / 命令面板组（互不依赖，任意顺序）
       ↓
handleEvent（永远最后——它调用其余全部）
```

**四条硬约束**：

1. **批次 3 → 批次 4**：`inSelRange` 与 `cardHidden` 被渲染层调用，先拆渲染层才不会回指。
2. **批次 5 的 `handleSlash` → 批次 4 的 `dialogActivate`**：单向，**不存在循环依赖**
   （实测见 §5 批次 4）。所以 `handleSlash` 必须先搬。
3. **`handleEvent` 永远最后**：它是总入口，调用其余所有 `handle*`。
4. **每步都必须以「编译通过 + 测试全绿 + 已推送」结束**，不留中间态。

## 7. 每批的完成判据（Definition of Done）

1. `cabal build all` = 0（不是「单库构建通过」——见 QWEN.md 的 27 项 other-modules 教训）
2. `cabal test trha-cli-test` = 667 examples, 0 failures
3. `cabal test trha-test` 至少跑一次（UIs 间接依赖 kernel 类型）
4. 该批对应的 tmux 实测项全部通过（不接受「应该没问题」）
5. 新增模块已登记进 `trha.cabal` 的 `other-modules`（**不要**登记进 `trha-cli.cabal` 的
   test-suite，除非测试真的编译它——`65d53b7` 踩过这个坑：登记后 test-suite 要拉
   brick/vty 依赖）
6. 提交后立即 `git push`（AGENTS.md 硬规矩，判据 `git rev-list --count origin/main..HEAD` = 0）

## 8. 风险与回滚

| 风险 | 缓解 |
|---|---|
| 长函数块（`drawStatus` 184 行、`drawDialog` 310 行、`handleSlash` 900 行）删除时误伤相邻代码 | 分段删除；每次删除后立即编译；先 `git show HEAD:<file>` 核对原文 |
| 迁移时漏构造子分支 | 逐分支核对（已发生 `diffAttrOf` 漏 `CPlain`） |
| 拆分后 test-suite 编译失败 | 新模块只登记 library；测试不需要就不登记 |
| 行为回归无法被 667 例覆盖 | 每批都跑该批的 tmux 实测清单 |
| 上下文耗尽导致半成品 | 每批独立提交；任何一批中途停下都处于**可编译可回滚**状态 |

**回滚**：每批一个提交，`git revert <sha>` 即可；批次 0-a/0-b 已验证可独立回滚。

## 9. 状态跟踪

- [x] 批次 0-a：`UI.Render.Spans`（`65d53b7`）
- [x] 批次 0-b：`UI.Brick.Draw.Status` 文本层（`237d487`）
- [x] 批次 1：`drawStatus` 完整迁移（`1755d7d`，含 13 个 `status*`）
- [x] 批次 2：侧栏与对话框（`UI.Brick.Draw.{Sidebar,Dialog,Settings}` + `UI.Render.Settings`）
- [x] 批次 3：消息区渲染（`fc12937`/`a0633b3`/`09808dd`）
- [ ] 批次 4：交互层——**大部分完成**（`UI.Brick` 4414 → 2923，-33.8%）
  - [x] `UI.Brick.Input`（`cdb7909`）：promptIsEmpty/editorValue/editorCursor/alwaysConfirmText
  - [x] `UI.Brick.DialogKeys`（`6e1aaa5`/`7cc3527`/`3bb87d6`）：dialogAppend/dialogDelete/withCommands/modifyTop/scrollBottom/persistSelection/chooseProvider
  - [x] `UI.Brick.Toast`（`bd85b22`）：showToast
  - [x] `UI.Brick.RunControl`（`099fbef`/`7383fd6`/`53c229b`）：中断审批组 6 个 + runShellCommand + approveAndRun
  - [x] `UI.Brick.Apply`（`a8337a4`/`de44aeb`/`70a2147`）：applyLanguage/applyTheme/openSettingsPanel/modeAction
  - [x] `UI.Brick.Selection`（`4be82a9`）：选区组 7 个 + copyToClipboard
  - [x] `UI.Brick.MessageOps`（`e75d246`/`f9de435`）：now/appendMsg/setWindowTitle
  - [x] `UI.Brick.SessionView`（`5430ee8`/`dc7b41a`/`dcc9e98`）：localSessionLines/blocksToMessages/refreshSidebar
  - [x] `UI.Brick.Chat`（`49d9d53`）：handleChatWith（84 行）
  - [ ] **阶段 3 最后一项**：`resumeSession`（167 行，`Brick.hs` 450 起）
  - [ ] 命令面板组（`paletteItemsFor`/`refreshPalette`/`movePalette`/`runPaletteItem`）
  - [ ] `dialogActivate`(802)/`handleDialogKey`(755)/`handleChatKey`(915)/`handleChatEnter`(1035)
  - [ ] `handleSlash`（503 行，2073 起）——等上述依赖全部外置后才可搬
  - [ ] `handleEvent`（最后，总入口）

**搬一个函数的固定四处改动**（本会话反复踩坑后的结论）：

```
① 原处删除定义   ② 原处 import 补符号
③ 新处实现 + 导出 ④ 新处 import 补依赖
```

少一处就编译不过。前三处是 `helpTextFor` 一次踩全的。

**边界锚点只认函数名，不认注释**：`handleChatWith` 那次用
`-- | Send a chat message` 当起点，结果删掉了相邻的 `handleChat` 与
`expandFileReferences`（126 行），靠 `git checkout` 回退后改用
`handleChatWith ::` 才对。
- [ ] 批次 5：命令层（`handleSubmit`/`handleSlash` 861 行/`runShellCommand`）
- [ ] 批次 5b：命令定义单一来源 + 一致性测试（**建议优先于批次 5 主体**）

**2026-11-04 的两次纠错记录**：

1. 「批次 4 存在强连通环」——**错误**。实测 `rg` 统计证明 `handleSlash` 不回调
   `dialogActivate`，依赖是单向 DAG。
2. 「`handleSlash` 90+ 分支、900+ 行」——**高估**。实测 861 行、28 个字面分支、
   41 个命令名。
