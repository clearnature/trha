# Markdown 渲染进 brick：完整移植计划

目标：在 brick 侧新增 `Brick.Widgets.Markdown`，**完整覆盖** `md.go`（`/home/yanli/work/DeepSeek-Reasonix/internal/frontend/termrender/md.go`，553 行）的能力，trha 侧改为委托。

---

## 1. 现状与目标

| 项 | 现状 |
|---|---|
| Reasonix 侧 | `md.go` 553 行，用 `goldmark` 解析、自己做 AST → 带样式终端文本的渲染 |
| brick 侧 | **无任何 Markdown 能力** |
| trha 侧 | `UI/Render/Markdown.hs`（自研子集解析器，`MdBlock`/`MdSpan`），只支持代码块、粗体、行内码 |
| Haskell 生态 | `commonmark` 0.3.1（纯 Haskell，符合 CommonMark 规范）；`commonmark-extensions` 提供表格 |

目标产物：`3rdparty/brick/src/Brick/Widgets/Markdown.hs`，输出 `Widget n`，并提供纯函数层便于测试。

---

## 2. 能力对照表（逐函数）

`md.go` 的 18 个函数，逐一对应到 Haskell 侧：

### 2.1 块级

| `md.go` | 能力 | Haskell 侧 | 阶段 |
|---|---|---|---|
| `renderBlocks` | 遍历子节点 | `renderBlocks` | P1 |
| `renderBlock` | 按节点类型分派（switch 9 个 case） | `renderBlock`（`case nodeType`） | P1 |
| `renderHeading` | H1–H6，按级别加样式 | `renderHeading` | P1 |
| `renderParagraph` | 段落 | `renderParagraph` | P1 |
| `renderTextBlock` | 紧凑文本块（列表项内） | `renderTextBlock` | P1 |
| `renderList` | 有序/无序、嵌套缩进 | `renderList` | P1 |
| `renderFenced` | 围栏代码块 + 语言标签 | `renderFenced` | P1 |
| `renderBlockquote` | 引用块（左侧竖线） | `renderBlockquote` | P1 |
| `renderBlock` 的 `ThematicBreak` | 分隔线 | `renderThematicBreak` | P1 |
| `renderTable` | 表格：列宽计算 + 对齐 | `renderTable` | P3 |
| `renderTableRow` | 单行渲染（表头分隔线） | `renderTableRow` | P3 |
| `collectCells` | 提取单元格文本 | `collectCells` | P3 |

### 2.2 行内

| `md.go` | 能力 | Haskell 侧 | 阶段 |
|---|---|---|---|
| `renderInlineBlock` | 行内块的入口 | `renderInlineBlock` | P2 |
| `appendInline` | strong / em / code span / link | `appendInline` | P2 |
| `collectInline` | 行内扁平化为纯文本（copy 用） | `collectInline` | P2 |
| `italic` | 斜体 | `styledItalic` | P2 |

### 2.3 文本处理

| `md.go` | 能力 | Haskell 侧 | 阶段 |
|---|---|---|---|
| `fixCJKEmphasis` | **中文强调修复**：`**粗**` 紧贴汉字时 goldmark 不识别 | `fixCjkEmphasis` | P4 |
| `isCJKPunct` | CJK 标点判定 | `isCjkPunct` | P4 |
| `isSpace` | 空白判定（含全角空格） | `isSpaceChar` | P4 |
| `wrapAnsi` | 按列宽折行（不切 emoji / 宽字符） | `wrapText` | P4 |
| `RenderCopy` | 纯文本导出（供复制） | `renderMarkdownPlain` | P4 |

### 2.4 样式

`md.go` 的样式来自 `termrender/style.go` 与主题。Haskell 侧不绑死颜色，改为**接受一个样式策略**（与本次已合入的 `GlyphFit`/`FilterList` 同一种设计）：

```haskell
data MdStyle = MdStyle
  { msHeading  :: Int -> Text -> [Text]   -- 级别 → 渲染后的行
  , msStrong   :: Text -> Text
  , msEm       :: Text -> Text
  , msCode     :: Text -> Text
  , msLink     :: Text -> Maybe Text -> Text
  , msQuoteBar :: Text
  , msBullet   :: Bool -> Int -> Text     -- 有序/无序、序号
  , msRule     :: Int -> Text             -- 分隔线（宽度）
  , msIndent   :: Int -> Text
  }
```

默认实现 `plainStyle`（无颜色，用 ASCII 标记）使模块在无主题环境下也可用、可测。

---

## 3. 模块与文件划分

```
3rdparty/brick/src/Brick/Widgets/Markdown.hs        渲染器（AST → Widget n）
3rdparty/brick/tests/Markdown.hs                    测试
```

单文件，内部分层（不拆多文件，避免 cabal 登记负担）：

```haskell
-- 公开 API
renderMarkdown   :: MdStyle -> Int -> Text -> Widget n   -- 宽度 → Widget
renderMarkdownRaw :: MdStyle -> Int -> Text -> [Text]    -- 纯函数层，测试用
renderMarkdownPlain :: Int -> Text -> Text               -- 对应 RenderCopy

-- 内部：块级
renderBlocks, renderBlock, renderHeading, renderParagraph, renderTextBlock
renderList, renderFenced, renderBlockquote, renderThematicBreak
renderTable, renderTableRow, collectCells

-- 内部：行内
renderInlineBlock, appendInline, collectInline, styledItalic

-- 内部：文本处理
fixCjkEmphasis, isCjkPunct, isSpaceChar, wrapText
```

**关键设计**：核心逻辑全部走 `renderMarkdownRaw`（`Text -> [Text]`），`renderMarkdown` 只是把 `[Text]` 转成 `vBox . map txt`。这样测试断言的是纯函数输出，不依赖 Widget 比较。

---

## 4. 依赖

| 包 | 用途 | 是否已有 |
|---|---|---|
| `commonmark >= 0.2` | Markdown 解析（AST） | ❌ 需加进 `brick.cabal` library |
| `commonmark-extensions` | 表格扩展（`extast.Table`） | ❌ 需确认版本兼容 |

**风险与对策**：如果 `commonmark-extensions` 与 `commonmark 0.3` 版本不匹配，退路是自己解析表格（`md.go` 的 `renderTable` 只处理 GFM 管道表，语法简单，约 60 行）。

---

## 5. 分阶段交付

每个阶段独立可验证、独立成 PR 增量。

### P0：打通 AST（0.5 天）
- 读 `commonmark` 的 `Commonmark/Types.hs`（`Node`/`NodeType`/`HasChildren`/`NodeRange`），确认遍历方式
- 写最小 `renderMarkdownRaw`：只处理 `Paragraph` 的纯文本
- 验收：`renderMarkdownRaw plainStyle 80 "hello" == ["hello"]`

### P1：块级（1 天）
- `renderHeading` / `renderParagraph` / `renderTextBlock` / `renderList` / `renderFenced` / `renderBlockquote` / `renderThematicBreak`
- 验收：7 个构造各一个用例 + 嵌套列表

### P2：行内（0.5 天）
- `appendInline`：strong / em / code span / link
- `collectInline`：扁平化
- 验收：粗体、斜体、行内码、链接各一例

### P3：表格（1 天）
- `renderTable` / `renderTableRow` / `collectCells`
- 列宽计算、三档对齐（左/中/右）、表头分隔线
- 验收：2×2 表、含中文的表（列宽按 `TextWidth` 算，不是字符数）

### P4：CJK 修复与折行（1 天）
- `fixCjkEmphasis`：读懂 `md.go` 的意图（goldmark 要求 `**` 两侧是空白或标点，汉字不算），在**解析前**给紧贴汉字的强调标记插入零宽分隔或改用等效写法
- `wrapText`：按列宽折行，不切 grapheme cluster（复用已合入的 `Brick.Widgets.TextWidth`）
- `renderMarkdownPlain`：对应 `RenderCopy`
- 验收：`"这是**粗体**文字"` 能正确加粗；长中文段落折行后每行不超宽

### P5：trha 委托（0.5 天）
- `UI/Render/Markdown.hs` 保留 `MdBlock`/`MdSpan`（被 6 个模块使用），内部改为调用 brick
- 跑 `cabal test trha-cli-test`（687 例）
- 验收：零回归

**合计约 4.5 天**，可拆成 3 个 PR（P0–P2 / P3 / P4–P5）。

---

## 6. 测试策略

`3rdparty/brick/tests/Markdown.hs`，与已合入的 `FilterList`/`TextWidth`/`GlyphFit` 同风格（QuickCheck + `main :: IO Bool`）。

### 不变量（QuickCheck）
1. **幂等**：`render (render x) == render x` 不成立（Markdown 不是幂等的），改为：
   **不崩溃**：任意输入（含畸形 Markdown）都能返回，不抛异常
2. **行宽**：`all (\l -> textCells l <= width) (renderMarkdownRaw style width input)`
3. **无悬挂标记**：输出里不出现未闭合的粗体、行内码或链接标记（`md.go` 的 `appendInline` 保证了这点，测试要守住）
4. **纯文本导出无损**：`renderMarkdownPlain` 的输出不含 `*`/`#`/`` ` `` 这类标记字符

### 具体用例（对照 `md.go` 的能力清单，逐项一个）
- 标题 H1/H3/H6
- 段落含行内混排
- 无序/有序/嵌套列表
- 围栏代码块（带语言、不带语言）
- 引用块（含嵌套引用）
- 分隔线
- 表格（左/中/右对齐、含中文）
- `**粗**` 紧贴汉字（CJK 修复）
- 超长中文段落折行
- 空输入、只有空白、畸形输入（未闭合标记）

---

## 7. 验收判据

```
cabal test brick-tests     → 全绿，属性数从 47 增至 47 + N
cabal test trha-cli-test   → 687 examples, 0 failures（P5 后）
cabal build all            → 0
```

每个阶段单独跑一次 `cabal test brick-tests`，不留「最后一起验」。

---

## 8. 与 trha 现有实现的衔接

trha 的 `UI/Render/Markdown.hs` 有 `MdBlock`/`MdSpan` 两类型，被 `UI/Brick/Draw/Messages.hs` 等 6 个模块使用。

**P5 的改造方式**（与这次 `Picker`/`TextWidth` 的委托模式一致）：
- 保留 `MdBlock`/`MdSpan` 类型与 `parseMarkdown`/`renderBlocks` 签名
- 内部实现改为：`parseMarkdown = brick 的 AST 转换`、`renderBlocks = brick 的渲染`
- 调用点零改动

---

## 9. 可参考的开源实现

| 项目 | 语言 | 可借鉴的部分 |
|---|---|---|
| **`commonmark`** 的 `Commonmark/Html.hs` | Haskell | **AST 遍历的写法**（照搬结构，只换输出） |
| **`pandoc`** 的 `Text.Pandoc.Writers.Ansi` | Haskell | 终端样式输出、标题/列表的宽度处理 |
| **`mdcat`** | Rust | 终端渲染的成熟策略：表格列宽、折行、链接渲染 |
| **`glamour`** | Go | Reasonix 的同类实现（`md.go` 的上游思路） |
| **`brick`** 的 `Brick/Widgets/Table.hs` | Haskell | 表格控件（P3 可直接用） |

`commonmark` 的 `Commonmark/Html.hs` 尤其关键——它已经实现了「遍历 AST 并按节点类型输出」的完整骨架，我们只需把 HTML 输出换成 `[Text]` 行，**`renderBlock` 的分派结构可以逐行对照**。

---

## 10. 交付顺序与检查点

```
P0  AST 打通          → renderMarkdownRaw "hello" 可用
P1  块级 7 项          → 7 个用例通过
P2  行内 4 项          → 行内混排用例通过
P3  表格              → 含中文表格对齐正确
P4  CJK + 折行 + 纯文本 → "这是**粗体**文字" 与长段落折行通过
P5  trha 委托          → 687 例零回归
```

每个 P 结束后：`cabal test brick-tests` 全绿 → 提交 → 推送 → 下一个 P。
