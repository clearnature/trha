# 事故复盘：drawDialog 迁移失败（2026-11-04）

> 对象：把 `UI.Brick.drawDialog`（189 行）迁到 `UI.Brick.Draw.Dialog` 的尝试。
> 结果：**编译失败，全部回退，净产出 0**。
> 基线：`main = 15d97c9`。本文档记录根因、教训与重做方案，供后续批次复用。

--------------------------------------------------------------------------------

## 1. 事故经过

| 步骤 | 动作 | 结果 |
|---|---|---|
| 1 | `rg -n '^drawDialog\|^drawMessages'` 定位边界 | 得 506 / 817，**假定** `drawDialog` 占 506-816 |
| 2 | `sed -n '506,816p'` 追加到新模块 | ❌ 该范围含 **6 个**顶层定义，不只是 `drawDialog` |
| 3 | `git checkout` 回退，改取 506-694 | ❌ 仍多截了 8 行注释 |
| 4 | 再回退，取 506-686 | ✅ 边界正确（189 行） |
| 5 | 从 `Brick.hs` 分两段删除 189 行 | ✅ 删除完成 |
| 6 | `cabal build all` | ❌ 新模块缺 **20+ 符号**的 import，跨 5 个模块 |
| 7 | 开始逐个补 import | 上下文耗尽，无法完成 |
| 8 | `git checkout` 回退，清理临时文件 | ✅ 恢复到 `15d97c9`，`build=0` |

第 2 步误追加的内容（事后查明）：`resumeSession`、`applyLanguage`、`applyTheme`、
`localSessionLines`、`blocksToMessages` —— 5 个与渲染无关的函数，其中
`resumeSession`/`applyLanguage`/`applyTheme` 还是 `EventM` 动作，本就不该进渲染模块。

## 2. 根因分析

### 根因 1：边界判定用了「下一个同类函数」而不是「范围内全部顶层定义」

我依据 `^drawMessages` 的位置反推 `drawDialog` 的结束行，但两者之间还隔着 5 个
非 `draw*` 的函数。**函数边界只能由「下一个顶层定义」确定，与名字前缀无关。**

正确做法：

```bash
# 列出范围内的全部顶层定义，只看第一个匹配项的真实结束位置
sed -n '506,816p' packages/app/CLI/UI/Brick.hs | rg -n '^[a-zA-Z][a-zA-Z0-9_]* ::'
```

这一步 5 秒就能做完，我却跳过了，代价是 3 轮追加/回退。

### 根因 2：依赖勘察放在搬迁**之后**

先搬、再编译、看缺什么——这是「让编译器告诉我依赖」。它对小函数有效
（`drawPalette` 只缺 3 项），对 189 行 + 13 个构造子的分发器则完全不经济：
一次编译只暴露部分错误，补 3 轮仍然可能不全。

正确做法：**搬之前**用一条命令列出全部符号来源，形成 import 清单。已勘察到的：

| 符号 | 归属模块 |
|---|---|
| `dialogCount`、`dialogModelsItems`、`dialogSessionsItems`、`dialogSkillsItems`、`approvalOptions`、`ApprovalOption(..)`、`SandboxSettings(..)` | `UI.Dialog` |
| `askCountdownText` | `UI.Interaction` |
| `isFavorite` | `UI.ModelPrefs` |
| `ModelInfo(..)`、`ProviderInfo(..)` | `Core.Types` |
| `SessionSummary(..)` | `Core.SessionSummary` |
| `configAskTimeout` | `Core.Types` |

> ⚠️ 上面这张表里，`strWrap` 的归属**未经验证**（`ghc-pkg` 未返回 brick 的模块列表，
> 我在事故当时的推测是 `Brick.Widgets.Core`）。下一轮搬迁前应对它单独执行一次
> `rg` 或试编译确认——**表格里凡是没跑过命令的条目都不可当作事实**。

### 根因 3：把「分发器」当成普通函数

`drawDialog` 的结构是 `case d of` 对 **13 个 `Dialog` 构造子**分支，每个分支读不同
类型的字段（`ModelInfo`/`SessionSummary`/`ProviderInfo`/`SkillInfo`/`AgentInfo`/
`ThemeInfo`/`SandboxSettings`/`ProviderPreset`）。它天然是「整个 Dialog 家族的交汇点」，
不是一个自包含的渲染函数。

体积接近不代表难度接近：`drawSettingsPanel`（106 行）只碰 `SettingsPanel` 一个类型，
一次就搬成功；`drawDialog`（189 行）碰 8 个类型、5 个模块。

### 根因 4：上下文预算没有预算

第 5 步之后，为了精确删除 189 行，我连续做了 3 次大块读取（106 + 67 + 52 行）。
到第 6 步编译时，已经没有余量做「补 import × 3 轮」。**搬迁 150 行以上的函数时，
读取本身的成本必须计入预算**，否则会在「删完了但补不完」的位置断掉——那是最坏的位置，
因为工作区处于编译失败状态。

## 3. 与成功案例的对比

| 维度 | `drawSettingsPanel`（成功） | `drawDialog`（失败） |
|---|---|---|
| 行数 | 106 | 189 |
| 触及类型 | 1（`SettingsPanel`） | 8 |
| 触及模块 | 2（`UI.SettingsView`、`UI.State`） | 5 |
| 依赖勘察时机 | **搬之前**（先查清再动手） | 搬之后（靠编译试错） |
| 前置动作 | 先把纯渲染层搬到 `UI.Render.Settings` | 无 |
| 结果 | 一次通过 | 回退 |

**关键差异不是行数，是「依赖面是否在搬迁前封闭」。**

## 4. 教训（可执行规则）

1. **边界规则**：用 `sed -n 'A,Bp' | rg '^[a-zA-Z][a-zA-Z0-9_]* ::'` 列出范围内全部
   顶层定义；起点 = 目标函数，终点 = **下一个任意顶层定义**（不是下一个同类函数）。
2. **依赖前置规则**：搬迁前必须产出 import 清单（`rg -l "^sym ::"`），补进提交说明。
   凡是无法在一条命令内列全的依赖，说明还没准备好搬。
3. **分发器规则**：`case` 分支数 ≥ 5 的函数，先把 `where` 内的局部函数
   （`approvalOptionLabel`、`confirmOption`、`queryRow`、`dialogQueryOf`、`row` 等）
   提到顶层或独立模块，再搬主体——局部分支会随主体一起搬家，扩大一次性改动面。
4. **预算规则**：搬迁 >150 行 或 依赖 >10 符号时，先出方案（含 import 清单与删除顺序），
   单独一轮执行；不要在同一轮里既勘察又搬迁。
5. **回退规则**：补 import 若超过 3 轮仍未通过，立即 `git checkout` 回退。
   **留下编译失败的仓库比「这轮没做完」更糟**——前者会让下一个人无法开始。

## 5. 重做方案（多路径）

### 路径 A：三步走（推荐）

1. **提局部函数**：把 `drawDialog` 的 `where` 内绑定提为模块级纯函数
   （`approvalOptionLabel`、`confirmOption`、`dialogQueryOf`、`rowFor` 等），
   `drawDialog` 改为调用。此步零行为变化，可单独提交。
2. **出 import 清单**：按 §2 根因 2 的表，一次性写全新模块的 import 头并**先单独编译**
   （此时新模块还没有函数体，编译通过说明 import 面正确）。
3. **搬主体**：删除 `Brick.hs` 的 189 行，新模块加函数体，编译。

### 路径 B：先拆分再搬迁

把 `drawDialog` 按 `Dialog` 构造子拆成 8-13 个小函数
（`drawModelsDialog`、`drawSessionsDialog`、`drawApprovalDialog` …），
每个 10-25 行，再逐个搬。优点是每个都能独立验证；缺点是改变现有结构，
且 `row`/`queryRow` 这些共享辅助要额外设计参数传递。

**取舍**：路径 A 保持结构不变、风险集中于「import 一次写对」；路径 B 更细但引入
结构性改动。**推荐 A**——拆分是另一件事（可以之后再按功能拆 dialog 家族），
不该和「模块搬迁」混在一轮。

## 6. 本次事故的净影响

- 代码：0 行变更（全部回退，`main = 15d97c9`，`build=0`，`main == origin/main`）
- 时间：约 8 步工具调用
- 留下的资产：本文档 + §2 根因 2 的依赖表（下一轮可直接用）

## 7. 已确认可复用的结论

以下事实在本轮勘察中得到，后续批次不必再查：

1. `UI.Brick` 的 `ResourceName` 定义在 **`UI.State`**（244 行），`UI.Brick` 只是重导出。
2. `SettingsPanel` / `SettingsTab` / `SettingsFocus` / `tabLabel` / `tabList` 在
   **`UI.State`**，不在 `UI.Dialog`；`FocusTabs` 等是 `SettingsFocus` 的构造子，
   必须 `SettingsFocus(..)` 整体导入。
3. `piId` / `piLabel` / `piDesc` 是 **`PickerItem`** 的字段（`UI.Render.Picker`）；
   `SlashCommand` 用的是 `scCommand`/`scHasArg`/`scPicker`/`scDesc`。
4. `borderWithLabel` 在 `Brick.Widgets.Border`；`attrName`/`AttrName` 在 `Brick` 顶层；
   `ResourceName` **不在** `Brick`。
5. `drawDialog` 的真实边界是 `Brick.hs` 的 **506-686**（189 行），基线 `15d97c9`。
