# Markdown 渲染：细粒度 TDD 分解

本文是 `markdown-in-brick.md` 的执行配套。区别在于：那份说「做什么」，这份说「**每条测试断言什么、先写哪个、红在哪**」。

---

## 0. 接口先定死（测试与实现共用，后续不再改）

```haskell
module Brick.Widgets.Markdown
  ( MdStyle(..)
  , plainStyle
  , renderMarkdownRaw      -- 纯函数层：测试断言这一层
  , renderMarkdown         -- Widget 层：只做 vBox . map txt
  , renderMarkdownPlain    -- 纯文本导出（对应 RenderCopy）
  ) where

data MdStyle = MdStyle
  { msHeading  :: Int -> Text -> Text        -- 级别(1..6) → 该行文本
  , msStrong   :: Text -> Text
  , msEm       :: Text -> Text
  , msCode     :: Text -> Text               -- 行内码
  , msLink     :: Text -> Text -> Text        -- 链接文字、URL
  , msBullet   :: Int -> Int -> Text          -- 层级、序号(0 = 无序)
  , msQuoteBar :: Text                        -- 引用左侧那条
  , msRule     :: Int -> Text                 -- 分隔线（给定宽度）
  , msIndent   :: Int -> Text                 -- 缩进（层级 → 空格）
  }

-- | 无颜色样式：用 ASCII 标记表达结构。使模块在无主题环境下可测、可用。
plainStyle :: MdStyle
plainStyle = MdStyle
  { msHeading  = \lvl t -> T.replicate lvl "#" <> " " <> t
  , msStrong   = \t -> "**" <> t <> "**"
  , msEm       = \t -> "*" <> t <> "*"
  , msCode     = \t -> "`" <> t <> "`"
  , msLink     = \t u -> t <> " (" <> u <> ")"
  , msBullet   = \lvl n -> if n == 0 then indent lvl <> "-" else indent lvl <> T.pack (show n) <> "."
  , msQuoteBar = "│ "
  , msRule     = \w -> T.replicate w "-"
  , msIndent   = indent
  }
  where indent lvl = T.replicate (lvl * 2) " "

renderMarkdownRaw :: MdStyle -> Int -> Text -> [Text]
renderMarkdown    :: MdStyle -> Int -> Text -> Widget n
renderMarkdownPlain :: Int -> Text -> Text
```

**为什么先定接口**：TDD 的「红」是编译失败。接口定死后，每个测试写出来就是红的，实现填进去就绿——不需要反复改签名。

---

## 1. 任务分解（22 个任务，每个 = 一条测试 + 一段最小实现）

### T0：AST 打通（5 个任务）

| ID | 测试名 | 输入 | 期望输出 | 实现要点 |
|---|---|---|---|---|
| T0.1 | `emptyInput` | `""` | `[]` | 解析空文档，无块 |
| T0.2 | `plainParagraph` | `"hello"` | `["hello"]` | `Paragraph` → 文本 |
| T0.3 | `twoParagraphs` | `"a\n\nb"` | `["a", "", "b"]` | 段落之间空一行 |
| T0.4 | `softBreakJoins` | `"a\nb"` | `["a b"]` | CommonMark 软换行合并成空格 |
| T0.5 | `neverCrashes` | 任意 `Text` | 不抛异常 | QuickCheck 属性，畸形输入 |

**T0.5 的判据**：`length (renderMarkdownRaw plainStyle 80 t) >= 0` 恒真（不抛异常即通过）。这是唯一一条「不验证内容」的测试，作用是兜住解析器对畸形输入的鲁棒性。

### T1：块级（9 个任务）

| ID | 测试名 | 输入 | 期望输出 |
|---|---|---|---|
| T1.1 | `h1` | `"# Title"` | `["# Title"]` |
| T1.2 | `h3` | `"### Sub"` | `["### Sub"]` |
| T1.3 | `unorderedList` | `"- a\n- b"` | `["- a", "- b"]` |
| T1.4 | `orderedList` | `"1. a\n2. b"` | `["1. a", "2. b"]` |
| T1.5 | `nestedList` | `"- a\n  - b"` | `["- a", "  - b"]` |
| T1.6 | `fencedCode` | `"```\nx\n```"` | `["x"]` |
| T1.7 | `fencedCodeLang` | `"```hs\nx\n```"` | `["x"]`（语言暂不渲染，见下方说明） |
| T1.8 | `blockquote` | `"> q"` | `["│ q"]` |
| T1.9 | `thematicBreak` | `"---"` | `["-" x width]`（宽度 80 时 80 个 `-`） |

**T1.7 的说明**：`md.go` 的 `renderFenced` 会保留语言标签（用于高亮）。第一版只保留代码内容，语言记在 TODO——因为语法高亮不在本模块范围（brick 无高亮器）。测试先断言代码内容正确。

### T2：行内（5 个任务）

| ID | 测试名 | 输入 | 期望输出 |
|---|---|---|---|
| T2.1 | `strong` | `"**b**"` | `["**b**"]` |
| T2.2 | `emphasis` | `"*i*"` | `["*i*"]` |
| T2.3 | `codeSpan` | `` "`c`" `` | `` ["`c`"] `` |
| T2.4 | `link` | 方括号文字紧跟圆括号 URL（中间无空格） | `["t (u)"]` |
| T2.5 | `mixedInline` | `"**a** *b* `c`"` | `` ["**a** *b* `c`"] `` |

### T3：表格（3 个任务）

| ID | 测试名 | 输入 | 期望 |
|---|---|---|---|
| T3.1 | `table2x2` | `"\| a \| b \|\n\|---\|---\|\n\| 1 \| 2 \|"` | 3 行，列对齐 |
| T3.2 | `tableAlign` | 带 `:---:` 的表格 | 居中列两侧留空 |
| T3.3 | `tableCjkWidth` | 含中文单元格 | 按 `textCells` 算列宽，不是字符数 |

### T4：CJK 与折行（4 个任务）

| ID | 测试名 | 输入 | 期望 |
|---|---|---|---|
| T4.1 | `cjkStrong` | `"这是**粗体**文字"` | `["这是**粗体**文字"]`（加粗生效，不被当普通文本） |
| T4.2 | `wrapWithinWidth` | 200 个汉字的段落，width=80 | 每行 `textCells <= 80` |
| T4.3 | `wrapKeepsEmoji` | 含 ZWJ emoji 的长文本 | 折行点不在 cluster 中间 |
| T4.4 | `plainHasNoMarkup` | 任意 Markdown | `renderMarkdownPlain` 输出不含 `*`/`#`/`` ` `` |

**T4.1 的判据**：`md.go` 的 `fixCJKEmphasis` 解决的正是这个问题——goldmark（以及 commonmark）按 CommonMark 规范要求 `**` 的闭合侧不能紧跟字母/数字，汉字属于字母类，所以 `这是**粗体**文字` 在标准解析器里**不是加粗**。测试断言「加粗生效」，实现必须做预处理（在 `**` 紧贴汉字时插入零宽空格或改写成等效标记再解析）。

---

## 2. 测试代码（T0 + T1 可直接运行）

`3rdparty/brick/tests/Markdown.hs`：

```haskell
{-# LANGUAGE OverloadedStrings #-}
module Markdown (main) where

import Brick.Widgets.Markdown
import Test.QuickCheck
import Test.QuickCheck.Test (isSuccess)
import qualified Data.Text as T

-- T0.1
prop_emptyInput :: Bool
prop_emptyInput = renderMarkdownRaw plainStyle 80 "" == []

-- T0.2
prop_plainParagraph :: Bool
prop_plainParagraph = renderMarkdownRaw plainStyle 80 "hello" == ["hello"]

-- T0.3
prop_twoParagraphs :: Bool
prop_twoParagraphs =
  renderMarkdownRaw plainStyle 80 "a\n\nb" == ["a", "", "b"]

-- T0.4
prop_softBreakJoins :: Bool
prop_softBreakJoins = renderMarkdownRaw plainStyle 80 "a\nb" == ["a b"]

-- T0.5  任意输入都不抛异常
prop_neverCrashes :: String -> Bool
prop_neverCrashes s =
  let out = renderMarkdownRaw plainStyle 80 (T.pack s)
  in length out >= 0        -- 求值不抛异常即通过

-- T1.1
prop_h1 :: Bool
prop_h1 = renderMarkdownRaw plainStyle 80 "# Title" == ["# Title"]

-- T1.2
prop_h3 :: Bool
prop_h3 = renderMarkdownRaw plainStyle 80 "### Sub" == ["### Sub"]

-- T1.3
prop_unorderedList :: Bool
prop_unorderedList =
  renderMarkdownRaw plainStyle 80 "- a\n- b" == ["- a", "- b"]

-- T1.4
prop_orderedList :: Bool
prop_orderedList =
  renderMarkdownRaw plainStyle 80 "1. a\n2. b" == ["1. a", "2. b"]

-- T1.5
prop_nestedList :: Bool
prop_nestedList =
  renderMarkdownRaw plainStyle 80 "- a\n  - b" == ["- a", "  - b"]

-- T1.6
prop_fencedCode :: Bool
prop_fencedCode =
  renderMarkdownRaw plainStyle 80 "```\nx\n```" == ["x"]

-- T1.8
prop_blockquote :: Bool
prop_blockquote = renderMarkdownRaw plainStyle 80 "> q" == ["│ q"]

-- T1.9
prop_thematicBreak :: Bool
prop_thematicBreak =
  renderMarkdownRaw plainStyle 80 "---" == [T.replicate 80 "-"]

main :: IO Bool
main = and <$> sequenceA
  [ isSuccess <$> quickCheckWithResult stdArgs { maxSuccess = 100 } prop_emptyInput
  , isSuccess <$> quickCheckWithResult stdArgs { maxSuccess = 100 } prop_plainParagraph
  , isSuccess <$> quickCheckWithResult stdArgs { maxSuccess = 100 } prop_twoParagraphs
  , isSuccess <$> quickCheckWithResult stdArgs { maxSuccess = 100 } prop_softBreakJoins
  , isSuccess <$> quickCheckWithResult stdArgs { maxSuccess = 100 } prop_neverCrashes
  , isSuccess <$> quickCheckWithResult stdArgs { maxSuccess = 100 } prop_h1
  , isSuccess <$> quickCheckWithResult stdArgs { maxSuccess = 100 } prop_h3
  , isSuccess <$> quickCheckWithResult stdArgs { maxSuccess = 100 } prop_unorderedList
  , isSuccess <$> quickCheckWithResult stdArgs { maxSuccess = 100 } prop_orderedList
  , isSuccess <$> quickCheckWithResult stdArgs { maxSuccess = 100 } prop_nestedList
  , isSuccess <$> quickCheckWithResult stdArgs { maxSuccess = 100 } prop_fencedCode
  , isSuccess <$> quickCheckWithResult stdArgs { maxSuccess = 100 } prop_blockquote
  , isSuccess <$> quickCheckWithResult stdArgs { maxSuccess = 100 } prop_thematicBreak
  ]
```

---

## 3. 红 → 绿 → 重构 的具体节奏

每个任务的循环是**固定的三步**，不跳步：

| 步骤 | 动作 | 可观察状态 |
|---|---|---|
| **红 1** | 写测试（函数还没有） | `cabal build` 报 `Variable not in scope: renderMarkdownRaw` |
| **红 2** | 只加**签名 + `undefined`** | 编译通过，测试 **运行时崩溃**（`Prelude.undefined`） |
| **红 3** | 实现最小逻辑 | 测试仍失败，但失败信息是断言差异（不是崩溃） |
| **绿** | 补足实现 | `cabal test brick-tests` 该条通过 |
| **重构** | 提取命名清晰的内部函数 | 测试仍绿 |

**为什么「红 2」必须有**：直接写实现会掩盖「测试本身是否真的在断言」这件事。先 `undefined` 再填，保证测试确实跑到了那段代码。

**批量推进的纪律**：一次只让**一个**测试变绿，避免「改一堆然后一起看」。T1 的 9 条可以按 T1.1→T1.9 顺序，每条一个提交。

---

## 4. 依赖顺序

```
T0.1 ─┬─→ T0.2 ─→ T0.3
      │     └───→ T0.4
      └─→ T0.5（最后加，它依赖解析器已存在）

T0.2 ─→ T2.1 ─→ T2.5        （行内先于块级列表：列表项里要用行内渲染）
T0.2 ─→ T1.1 ─→ T1.2
T2.1 ─→ T1.3 ─→ T1.4 ─→ T1.5
T0.2 ─→ T1.6、T1.8、T1.9
T1.*、T2.* ─→ T3.1 ─→ T3.2 ─→ T3.3
T2.* ─→ T4.1
T1.*、T2.* ─→ T4.2 ─→ T4.3 ─→ T4.4
```

**关键一条**：**T2（行内）要先于 T1.3/T1.4（列表）**——列表项里可能含粗体/链接，先有行内渲染才不会返工。

---

## 5. 每个任务的「完成」定义

一个任务算完成，必须同时满足：

1. 对应测试通过
2. `cabal build all` 无 warning（本模块）
3. `cabal test brick-tests` 全绿（不只是新测试）
4. 提交信息里写明「T<ID>：<测试名>」

**不做的事**：不在一个提交里同时推进两个任务、不为「将来可能用到」加参数、不为未通过的测试写实现。

---

## 6. 与已合入模块的一致性检查点

每个阶段结束跑一次：

```
cabal test brick-tests    → 属性数从 47 递增
cabal test trha-cli-test  → 687 examples, 0 failures（P5 之前不应变化）
cabal build all           → 0
```

若 `trha-cli-test` 数量变化，说明改到了 trha 的既有行为——立即停下查。
