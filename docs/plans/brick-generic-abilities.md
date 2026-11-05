# 从 trha 泛化出可完善 brick 的通用能力

> 基于 trha 的工程经验，对照 `/data/work/functional-programming/hs/` 下 7 个
> brick 扩展包的抽象层级，给出「哪些该进 brick 核心、哪些该做扩展包、哪些
> 留在应用层」的分层方案。

## 1. 参考方案的抽象层级（已查证）

brick 生态的扩展包（`/data/work/functional-programming/hs/brick-*`）遵循同一模式：

```
Brick.Widgets.X                    -- 顶层：X 类型 + renderX + handleXEvent
Brick.Widgets.X.Internal.Types     -- 数据类型
Brick.Widgets.X.Internal.Render    -- 渲染（纯函数）
Brick.Widgets.X.Internal.Actions   -- 状态转换（纯函数）
```

实例：

| 包 | 模块 | 解决的问题 |
|---|---|---|
| `brick-calendar` | `Brick.Widgets.Calendar` + `Internal/{Month,Utils,Core,Actions}` | 月历组件 |
| `brick-filetree` | `Brick.Widgets.FileTree` + `Internal/{Types,Render,Actions}` | 文件树 |
| `brick-tabular-list` | `Brick.Widgets.TabularList` + `{Types,Mixed,Grid}` + `Internal/{Common,Lens}` | 表格 |
| `brick-list-search` | `Brick.Widgets.List.Search` | 在 `List` 中搜索**跳转** |
| `brick-panes` | `Brick.Panes` | 分栏 |
| `brick-dropdownmenu` | `Brick.Widgets.DropDownMenu` | 下拉菜单 |
| `brick-skylighting` | `Brick.Widgets.Skylighting` | 语法高亮 |

**关键设计**：`handleXEvent :: BrickEvent n e -> X -> EventM n X` —— 事件处理
返回**组件自己的状态** `X`，而不是全局 `AppState`。这正是 brick 缺失的
「局部状态」模式，也是这些包能复用的原因。

## 2. trha 与参考方案的对照

### 2.1 已有现成方案、trha 却在自建的

| trha 模块 | 行数 | 对应开源方案 | 差距 |
|---|---:|---|---|
| `UI/Render/Picker.hs` | ~200 | `brick-list-search` | **语义不同**：我们做「查询过滤」（`filterItems`），它做「跳转到下一个可选项」；二者互补而非重复 |
| `UI/Brick/Draw/Sidebar.hs` | 76 | `brick-filetree` / `brick-panes` | 我们的侧栏是「会话/文件/待办列表」，不是文件树；分栏部分可用 `brick-panes` |
| `UI/Render/MessageList.hs` | 154 | `brick-tabular-list` | 消息列表是「变高行 + 折叠态」，表格是「等宽列」，不通用 |
| `UI/Render/Markdown.hs` 的代码块 | — | `brick-skylighting` | 我们只做边框+语言标签，没做语法高亮；**这部分可以直接采用 skylighting** |
| `UI/Brick/DialogActivate.hs` 的菜单 | 316 | `brick-dropdownmenu` | 我们的对话框是模态栈，不是下拉菜单；语义不同 |

**结论**：真正重复造轮子的只有 **代码块语法高亮**（应改用 `brick-skylighting`）。其余是语义差异，不是重复。

### 2.2 trha 独有、brick 与扩展包都没有的

| trha 模块 | 行数 | 能力 | brick 有吗 | 扩展包有吗 |
|---|---:|---|---|---|
| `UI/Dialog/Stack.hs` | 41 | 模态栈（push/pop/顶层拥有焦点） | ❌ | ❌ |
| `UI/Dialog/Escape.hs` | 44 | Esc 多级层级 + 5 秒双击中断 | ❌ | ❌ |
| `UI/TextWidth.hs` | ~120 | 按**显示列宽**截断（含 CJK 双宽） | ❌ | ❌ |
| `UI/Theme.hs` | 287 | 主题结构 → `AttrMap` 的映射机制 | 只有 `attrMap` 原语 | ❌ |
| `UI/Render/Spans.hs` | 122 | span 列表按宽度截断 + 属性切换 | ❌ | ❌ |
| `UI/Interaction.hs` | 281 | 命令分层表（`layerTable`） | ❌ | ❌（偏应用） |
| `UI/Render/Picker.hs` | ~200 | 查询串过滤 + 选择移动 + 空态 | ❌ | 部分（搜索而非过滤） |

## 3. 分层方案

### Layer 0 — 进 brick 核心（`Brick.Widgets.Core`）

| 能力 | 现状 | 建议 |
|---|---|---|
| **按显示宽度截断文本** | brick 无；我们用 `TW.takeCells`（`UI/TextWidth.hs`） | 增加 `hLimitText :: Int -> Text -> Widget n` 或 `textWidth :: Text -> Int`。这是**每个 TUI 都会手写**的东西（CJK 双宽、组合字符、emoji），brick 目前只提供 `hLimit`（按 Widget 限宽，不解决「截断后加省略号」） |

**为什么该进核心**：`hLimit` 到宽度不够时是**裁剪 Widget**，不提供「截断并加 `…`」的语义。任何需要「一行摘要」的地方都要自己算 `TextWidth`。

### Layer 1 — 新建 brick-* 扩展包

#### `brick-dialog`（对应 `UI/Dialog/{Stack,Escape}.hs`）

```
Brick.Widgets.Dialog
  DialogStack a            -- 泛型栈，不绑定具体 Dialog 类型
  push / pop / top / null
  handleDialogKeys         -- Tab/Enter/Esc 的标准分派
Brick.Widgets.Dialog.Escape
  EscFlags / EscOutcome    -- 已是通用字段
  resolveEscape            -- 优先级判定
  escPress                 -- 双击窗口
```

**泛型化要点**：`Stack.hs` 目前只依赖 `Dialog` 类型，把 `Dialog` 换成类型参数 `a` 即可；`Escape.hs` 的 `EscFlags` 本身就是通用概念（选区/栈/shell/补全）。

**为什么值得做**：`docs/plans/ide-information-architecture.md:225` 已论证 brick 不提供层栈，而**任何**有多个模态面板的 TUI 都要重建一遍。

#### `brick-theme`（对应 `UI/Theme.hs`）

```
Brick.Theme
  Theme                    -- 语义色板（primary / border / dim …）
  themeToAttrMap           -- Theme -> AttrMap
  withTheme                -- 作用域内覆盖
```

**为什么值得做**：brick 的 `attrMap` 是「名字 → 属性」平表，没有层叠/变量/作用域。前端有 CSS variables，TUI 里每个应用都在手动做同样的映射。

#### `brick-spans`（对应 `UI/Render/Spans.hs`）

```
Brick.Widgets.Spans
  Span                     -- (属性, 文本)
  renderSpans              -- 按列宽截断 + 属性切换
  spansWidth               -- 计算总宽度
```

**为什么值得做**：`UI/Render/Spans.hs` 的 `splitAtWidth`/`truncLine` 是通用算法（含 CJK 双宽），与 trha 业务无关。

### Layer 2 — 留在 trha（应用特化）

| 模块 | 理由 |
|---|---|
| `UI/Render/Markdown.hs` | Markdown 子集解析 + 渲染策略是应用选择 |
| `UI/Render/ToolCard.hs` | 工具卡是 agent harness 的领域模型 |
| `UI/Render/Message.hs` / `MessageList` / `MessageBody` | 消息模型（角色/工具/折叠/统计）是 trha 特有 |
| `UI/Brick/Draw/*`（6 个） | 全部从 `AppState` 取数据，强耦合 |
| `UI/Brick/*`（22 个） | 同上 |
| `UI/I18n/*` | 9 种语言的词表是 trha 的产品决策 |
| `UI/Commands/*` | 命令体系依赖 trha 的 `Bridge`/`Command` 类型 |

## 4. 实施优先级

| 优先级 | 动作 | 理由 | 工作量 |
|---|---|---|---|
| **P0** | 采用 `brick-skylighting` 替代自建代码块高亮 | 唯一真正重复造轮子的地方，且我们目前根本没做高亮 | 小（换依赖 + 改 `UI/Render/Markdown` 的渲染分支） |
| **P1** | 抽出 `brick-dialog`（`Stack` + `Escape` 泛型化） | brick 明确没有，社区也没人做，复用价值最高 | 中（约 85 行泛型化 + 测试） |
| **P2** | 给 brick 提 `takeCells` 的 issue/PR | 每个 TUI 都要写，改动小、收益广 | 小（约 30 行 + 文档） |
| **P3** | 抽出 `brick-spans` | 通用算法，但依赖 `TextWidth`（若 P2 被接受则更简单） | 中（约 120 行） |
| **P4** | 抽出 `brick-theme` | 价值取决于应用是否愿意接受固定的 `Theme` 语义 | 中（约 200 行） |

## 5. 不建议泛化的

| 能力 | 理由 |
|---|---|
| 动画/过渡 | 终端只有字符网格，`threadDelay` + 重绘在视觉上不成立 |
| 像素级图形 | sixel/kitty 协议兼容性差，不是所有终端支持 |
| 无障碍 | 终端本身没有可访问性层 |
| 响应式断点 | 窗口尺寸变化只能靠 `availableWidth` 手写分支，没有声明式方案 |
| 富文本排版 | 等宽字体 + SGR 属性是终端的能力上限 |

## 6. 一句话结论

trha 的 17852 行 UI 代码里，**真正能泛化回 brick 生态的只有约 500 行**：
对话框栈（85 行）、按列宽截断（120 行）、主题映射（287 行）。其余 17000+ 行
都是 agent harness 的领域逻辑——这恰好说明 brick 的定位是对的：**它提供原语，
应用负责组织**。可泛化的部分集中在「每个复杂 TUI 都会重写一遍的基础设施」，
而不是业务逻辑。
