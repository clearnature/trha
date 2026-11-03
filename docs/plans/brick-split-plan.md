# Brick.hs 按功能拆分计划

> 基线：`main = 237d487`（`UI.Brick` 4333 行 / 151 个顶层定义）。
> 行号均以该提交为准；每批执行后行号会漂移，以**函数名**定位而不是行号。
> 权威结构文档见 [`docs/architecture/architecture.md`](../architecture/architecture.md)；
> 平台差异见 [`docs/reference/windows-dev-notes.md`](../reference/windows-dev-notes.md)。

## 1. 为什么要拆

`packages/app/CLI/UI/Brick.hs` 已长到 **4333 行、151 个顶层定义**，把五类职责挤在
一个模块里：

| 职责 | 代表定义 | 数量 |
|---|---|---|
| 装配/入口 | `initialState`、`appFor`、`runTUI`、`themeAttrMap` | ~8 |
| 渲染 | `draw*` | 15 |
| 交互 | `handle*` | 13 |
| 命令 | `handleSlash`（90+ 分支） | 4 |
| 状态查询/纯辅助 | `msgHeight`、`cardHidden`、`sidebarDataFor`… | ~110 |

后果不是「文件长」这种审美问题，而是三条实际障碍：

1. **无法单测**：`EventM ResourceName AppState` 与 Brick 运行时绑定，任何 `handle*`
   都只能在真终端里验证。
2. **改一处要读全篇**：`drawStatus` 的 15 个 segment 与 `handleSlash` 的 90 个分支
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

## 3. 现状（已完成两批）

| 批次 | 提交 | 模块 | 迁出内容 |
|---|---|---|---|
| 0-a | `65d53b7` | `UI.Render.Spans` | `SpanTok(..)`、`spanToks`、`spanToksWith`、`fillLines`、`splitAtWidth`、`truncLine`、`diffAttrOf`、`spinnerFrame`、`boolText`、`isCompactionMark` |
| 0-b | `237d487` | `UI.Brick.Draw.Status` | `modelLabel`、`statusLine`、`pricesOf` |

两批验证：`cabal build all` = 0；`cabal test trha-cli-test` = **667 examples, 0 failures**。

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

**迁出**：`handleEvent`、`handleLeaderKey`、`handleCtrlCKey`、`handleCtrlDKey`、
`handleDialogKey`、`handleChatKey`、`handleChatEnter`、`handleAppEvent`、`handleSettingsKey`，
以及选区：`msgIndexAt`、`msgRowAt`、`inSel`、`finishSel`、`extendSel`、`copySelectionText`、
`moveCardFocus`、`nextCardFocus`、`toolCardIds`。

**为什么选区跟着交互层**：它们都是 `EventM` 里的鼠标/键盘行为，与渲染无关。但注意
`inSel`/`cardHidden` 被渲染层调用——若批次 3 先完成，这两个要留在渲染层或下沉到
`UI.Selection`（现有模块）。**执行顺序必须是批次 3 → 批次 4**，否则会产生回指。

**依赖**：`UI.State`、`UI.Dialog`、`UI.Selection`、`Core.Clipboard`、`Bridge.Scheduler`、
`UI.Event`（`AppEvent`）。

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

**迁出**：`handleSubmit`、`handleSlash`（90+ 分支）、`handleChat`、`handleChatWith`。

**依赖**：`UI.Commands`（`executeCommand`、`Command` 构造子）、`Bridge.Scheduler`（数十个
HTTP 调用）、`UI.Commands.Registry`（`parseCommand`）。

**验证点**（命令矩阵，见 [`docs/reference/cli-command-matrix.md`](../reference/cli-command-matrix.md)）：

1. 编译 + 667 例
2. tmux 逐个执行 90 条命令，记录 `OK` / `DIALOG` / `FAIL`
3. 重点回归本轮修过的：
   - `/switch` 无参 → 打开可选中对话框（`d3a1e7c`）
   - `/provider` → `DialogProviders`
   - `/recap` `/btw` `/review` → 返回真实摘要（`4835673`）
   - `/skip` `/reject` `/abandon` 无计划时提示「No pending plan …」（`ee7b365`）
   - `/mode <x>` 带参数走 `modeAction`（`7f34bb8`）

**风险**：`handleSlash` 900+ 行，分支之间**顺序敏感**（`_ | cmd == …` 守卫分支必须在
字面分支之后的正确位置）。搬运**只做剪切**，不改分支顺序、不改守卫条件。

---

## 6. 执行顺序与依赖关系

```
批次 1（状态栏）─┐
批次 2（对话框）─┤ 1、2 互不依赖，可并行
批次 3（消息区）─┘ ↓ 必须在批次 4 之前（inSel/cardHidden 的归属）
批次 4（交互）   ↓
批次 5（命令）
```

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
- [ ] 批次 1：`drawStatus` 完整迁移
- [ ] 批次 2：侧栏与对话框
- [ ] 批次 3：消息区渲染
- [ ] 批次 4：交互层
- [ ] 批次 5：命令层
