{-# LANGUAGE OverloadedStrings #-}

-- | 消息区的渲染：消息头、正文、工具卡、markdown 块。
--
-- 依赖方向：UI.Render.{Markdown,ToolCard,Message,Diff,Spans} ← 本模块 ← UI.Brick（装配）。
--
-- 与 drawDialog 的教训一致：一次只搬一组同职责函数，每步都能编译。
module UI.Brick.Draw.Messages
  ( cardHidden
  , roleStyle
  , messageHeader
  , messageBody
  , renderToolBody
  , renderBlocks
  , diffWidget
  , drawMessage
  , drawMessages
  , drawInput
  , drawPlanCard
  , drawPending
  ) where

import Brick
import Brick.Widgets.Border
import Brick.Widgets.Core
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Map.Strict as Map
import qualified Graphics.Vty as V
import Lens.Micro ((&), (.~), (^.))

import Core.Types (CLIConfig(..), PlanStepView(..), PlanView(..))
import Brick.Widgets.Edit (getEditContents, renderEditor)
import UI.Event (PendingMsg(..), RunState(..), runState)
import UI.Render.Diff
  ( DiffClass(..), DiffLayout(..), DiffRow(..), diffClass, diffLayout
  , looksLikeDiff, numberDiff, renderDiffRow )
import UI.Render.FilePart (filePartsOf, filePartLine, stripFileTokens)
import UI.Render.Markdown (MdBlock(..), MdSpan(..), parseMarkdown)
import UI.Render.Message (classifyError, errorHint, errorLabel)
import UI.Render.Spans
  ( SpanTok(..), diffAttrOf, fillLines, spanToks, spinnerFrame, truncLine )
import UI.Render.ToolCard
  ( ToolCard, ToolFold(..), tcDur, tcOutput, tcStatus, toolStatusLine )
import UI.Render.ToolSummary
  ( presentCard, shouldHideTool, toolDetailLines, toolHeadline )
import UI.Selection (inSelRange)
import UI.State (AppState(..), ChatMessage(..), ResourceName(..))

-- | 工具卡是否折叠隐藏（verbose 模式全展开；否则看用户折叠状态）。
cardHidden :: AppState -> ChatMessage -> Bool
cardHidden st m
  | appVerbose st = False
  | Map.lookup (msgId m) (appFolds st) == Just FoldExpanded = False
  | otherwise = maybe False shouldHideTool (msgTool m)

-- | 消息角色的显示样式：(属性, 括号标签)。
--
-- 错误按种类分类，让限流显示成限流而不是笼统失败（MiMo 的 @errorKind()@）。
roleStyle :: Text -> Text -> (AttrName, Text)
roleStyle role content = case role of
  "user"      -> (attrName "user", role)
  "assistant" -> (attrName "assistant", role)
  "tool"      -> (attrName "tool", role)
  "plan"      -> (attrName "plan", role)
  "system"    -> (attrName "system", role)
  "error"     -> (attrName "error", errorLabel (classifyError content))
  "thinking"  -> (attrName "system", "thinking")
  "step"      -> (attrName "timestamp", "step")
  "stats"     -> (attrName "timestamp", "stats")
  "compact"   -> (attrName "plan", "context")
  "retry"     -> (attrName "busy", "retry")
  "shell"     -> (attrName "tool", "shell")
  _           -> (attrName "header", role)

-- | 消息与流式块共用的表头行：@[role] timestamp@。
messageHeader :: Bool -> Text -> Text -> Text -> Widget ResourceName
messageHeader showTs role content time
  -- 每轮的记账行是纯文本行，不带括号。
  | role == "stats" = emptyWidget
  | otherwise = hBox (roleW : [timeW | showTs])
  where
    sty = roleStyle role content
    roleW = withAttr (fst sty) $ str $ "[" ++ T.unpack (snd sty) ++ "]"
    timeW = hBox [str " ", withAttr (attrName "timestamp") (str (T.unpack time))]

messageBody :: Bool -> Text -> Text -> Maybe ToolCard -> ToolFold -> Widget ResourceName
messageBody md role content tool fold
  | role == "stats" =
      padLeft (Pad 2) $ withAttr (attrName "timestamp") $ strWrap (T.unpack content)
  | otherwise =
      case tool of
    Just card -> renderToolBody card fold

    Nothing
      | role == "assistant" && md ->
          padLeft (Pad 2) $
            withAttr (attrName "assistant") $
              vBox (renderBlocks (parseMarkdown content))
      | role == "assistant" ->
          padLeft (Pad 2) $
            withAttr (attrName "assistant") $ strWrap (T.unpack content)
      | role == "error" ->
          padLeft (Pad 2) $
            vBox $
              [ strWrap (T.unpack content) ]
                ++ [ withAttr (attrName "status") (strWrap (T.unpack hint))
                   | Just hint <- [errorHint (classifyError content)] ]
      | role == "thinking" ->
          -- Reasoning is long; show the first lines plus a size hint (MiMo
          -- folds it behind "Thought for Xs").
          padLeft (Pad 2) $
            withAttr (attrName "system") $
              borderWithLabel (withAttr (attrName "system") $ str " thinking ") $
                vBox $
                  [ padLeftRight 1 $ strWrap (T.unpack l)
                  | l <- take 3 (filter (not . T.null) (T.lines content)) ]
                    ++ [ padLeftRight 1 $ withAttr (attrName "timestamp") $
                           str ("… (" <> show (T.length content) <> " chars)") ]
      | role == "step" ->
          padLeft (Pad 2) $
            withAttr (attrName "timestamp") $
              str ("── " <> T.unpack content <> " ──")
      | role == "compact" ->
          padLeft (Pad 2) $
            withAttr (attrName "plan") $
              borderWithLabel (withAttr (attrName "plan") $ str " context ") $
                padLeftRight 1 (strWrap (T.unpack content))
      | role == "retry" ->
          padLeft (Pad 2) $ withAttr (attrName "busy") $ strWrap (T.unpack content)
      | role == "shell" ->
          padLeft (Pad 2) $ withAttr (attrName "system") $ strWrap (T.unpack content)
      | role == "plan" ->
          -- plan/approval card (Reasonix plan-decision style)
          padLeft (Pad 2) $
            withAttr (attrName "plan") $
              borderWithLabel (withAttr (attrName "plan") $ str " Plan ") $
                vBox
                  [ padLeftRight 1 $ strWrap (T.unpack content)
                  , padLeftRight 1 $ withAttr (attrName "status") $
                      str "run /approve or /deny"
                  ]
      | otherwise ->
          case filePartsOf content of
            [] -> padLeft (Pad 2) $ strWrap (T.unpack content)
            refs ->
              -- Attachment tokens became file parts (M5-7): the prose keeps
              -- wrapping, each path gets its own row.
              let prose = stripFileTokens content
              in padLeft (Pad 2) $ vBox $
                   [ strWrap (T.unpack prose) | not (T.null prose) ]
                     ++ [ withAttr (attrName "timestamp") (str (T.unpack (filePartLine r)))
                        | r <- refs ]

-- | One tool card.  Collapsed: a family-specific headline (shell command,
-- path, pattern, task…).  Expanded: family detail lines, then the diff or
-- output preview.  @present@ renders as a card and skips the raw payload.
renderToolBody :: ToolCard -> ToolFold -> Widget ResourceName
renderToolBody card fold =
  padLeft (Pad 2) $ withAttr (attrName "tool") $
    case fold of
      FoldCollapsed -> str (T.unpack (toolHeadline card))
      FoldExpanded ->
        vBox $
          [ str (T.unpack l) | l <- toolDetailLines card ]
            ++ outputWidgets
            ++ [ withAttr (attrName "status") $ str (T.unpack (toolStatusLine st (tcDur card)))
               | Just st <- [tcStatus card] ]
  where
    outputWidgets
      | isJust (presentCard card) = []
      | looksLikeDiff (tcOutput card) = [diffWidget (tcOutput card)]
      | otherwise =
          [ withAttr (diffAttrOf (diffClass l)) $
              str (T.unpack ("  │ " <> truncLine l))
          | l <- tcOutput card ]


renderBlocks :: [MdBlock] -> [Widget ResourceName]
renderBlocks = map renderBlock
  where
    renderBlock (MdCodeBlock lang code) =
      padTop (Pad 1) $
        withAttr (attrName "codeBlock") $
          borderWithLabel (withAttr (attrName "codeLang") $ str (" " ++ T.unpack lang ++ " ")) $
            vBox [ strWrap (T.unpack l) | l <- T.lines code ]
    renderBlock (MdParagraph spans) = spanWrap spans
    renderBlock (MdHeading level spans) =
      padTop (if level <= 2 then Pad 1 else Pad 0) $
        withAttr (attrName "header") $
          str (T.unpack (T.replicate level "#" <> " ")) <+> spanLine spans
    renderBlock (MdListItem marker spans) =
      padLeft (Pad 2) $ str (T.unpack marker <> " ") <+> spanLine spans

    -- markers are stripped; the styling lives in the attribute
    spanWidget (MdPlain t) = str (T.unpack t)
    spanWidget (MdBold t)  = withAttr (attrName "mdBold") $ str (T.unpack t)
    spanWidget (MdCode t)  = withAttr (attrName "mdCode") $ str (T.unpack t)
    spanLine spans = hBox (map spanWidget spans)

diffWidget :: [Text] -> Widget ResourceName
diffWidget ls = Widget Greedy Fixed $ do
  c <- getContext
  let width = max 1 (c ^. availWidthL)
      lay = diffLayout width
      resolve n = attrMapLookup n (c ^. ctxAttrMapL)
      prefix = case lay of
        DiffInline   -> "  │ "
        DiffNumbered -> ""
      rows = [ r { drText = truncLine (drText r) } | r <- numberDiff ls ]
      imgs = [ V.text' (resolve (diffAttrOf (drClass r)))
                   (prefix <> renderDiffRow lay r)
             | r <- rows ]
  return $ emptyResult & imageL .~ V.vertCat imgs

-- | SpanTok / spanToks / fillLines / splitAtWidth / truncLine / diffAttrOf 等
-- 纯函数已抽到 UI.Render.Spans（见该模块），这里只保留渲染与交互。

-- | Greedy word fill 见 UI.Render.Spans.fillLines。

-- | Split the longest prefix whose display width fits @w@ columns.
-- 实现见 UI.Render.Spans.splitAtWidth。

-- | Render the assistant reply currently being accumulated.
-- A blinking cursor suffix signals that the stream is still open.

spanWrap :: [MdSpan] -> Widget ResourceName
spanWrap spans = Widget Greedy Fixed $ do
  c <- getContext
  let width = max 1 (c ^. availWidthL)
      resolve n = attrMapLookup (attrName n) (c ^. ctxAttrMapL)
      imgs =
        [ V.horizCat [ V.text' (resolve (tokAttr t)) (tokText t) | t <- ts ]
        | ts <- fillLines width (concatMap spanToks spans)
        ]
  return $ emptyResult & imageL .~ V.vertCat imgs

-- | Render a diff-shaped tool output: line numbers appear once the terminal
-- is wide enough, and each line keeps its add/remove/hunk colour.
-- | diffWidget 见 UI.Brick.Draw.Messages。

drawMessage :: CLIConfig -> Bool -> ToolFold -> ChatMessage -> Widget ResourceName
drawMessage cfg focused fold msg
  | msgRole msg == "thinking" =
      padLeftRight 1 $ vBox $
        [ hBox
            [ clickable (ThinkToggle (msgId msg)) $
                withAttr (attrName "system")
                  (str (if fold == FoldCollapsed then "▸ " else "▾ "))
            , withAttr (attrName "system")
                (str (T.unpack (fromMaybe "思考 (Ctrl+O)" (msgMeta msg))))
            ]
        ] ++ [ padLeft (Pad 2) $ withAttr (attrName "system")
                 $ strWrap (T.unpack (msgContent msg))
             | fold == FoldExpanded ]
  | otherwise =
  padLeftRight 1 $
    padTopBottom 1 $
      vBox $
        [ hBox
            [ if focused then withAttr (attrName "selection") (str "▶ ") else emptyWidget
            , messageHeader (configTimestamps cfg) (msgRole msg) (msgContent msg) (msgTime msg) ]
        , messageBody (configMarkdown cfg) (msgRole msg) (msgContent msg) (msgTool msg) fold
        ]
          ++ [ padLeft (Pad 2) $ withAttr (attrName "timestamp") (str (T.unpack m))
             | Just m <- [msgMeta msg] ]

-- | Render a parsed Markdown document as widgets.
-- Paragraph spans re-wrap at the context width with styling preserved
-- (see 'spanWrap'); fenced code blocks get a bordered card labelled with
-- their language; headings and list items render on one line.
-- | renderBlocks 见 UI.Brick.Draw.Messages。

-- | Word-wrap a paragraph of styled inline spans at the available width,
-- preserving each span's attribute on every wrapped line.
--
-- brick 3.0 removed the widget-level 'wrap'; this mirrors the render-time
-- reflow technique of 'txtWrapWith' (measure against the context width,

-- | Render the assistant reply currently being accumulated.
-- A blinking cursor suffix signals that the stream is still open.
drawPending :: CLIConfig -> PendingMsg -> Widget ResourceName
drawPending cfg pm =
  padLeftRight 1 $
    padTopBottom 1 $
      vBox
        [ messageHeader (configTimestamps cfg) "assistant" (pmContent pm) (pmStart pm)
        , messageBody (configMarkdown cfg) "assistant" (pmContent pm <> "▍") Nothing FoldCollapsed
        ]


drawMessages :: AppState -> Widget ResourceName
drawMessages st =
  withAttr (attrName "border") $
    borderWithLabel (withAttr (attrName "title") $ str " trha — agent harness · Messages ") $
      viewport MessageArea Vertical $
        vBox $
          case (appMessages st, visible, appPending st) of
            ([], _, Nothing) ->
              [ padAll 1 $ withAttr (attrName "timestamp") $
                  strWrap "No messages yet. Type something and press Enter, or /help for commands." ]
            (_, [], Nothing) ->
              -- Everything on screen was a quiet tool card (M6-7); say so
              -- instead of drawing an empty viewport.
              [ padAll 1 $ withAttr (attrName "timestamp") $
                  strWrap "All tool cards are hidden (quiet read/search). /verbose shows them." ]
            _ -> [ let -- 焦点标记只属于工具卡：之前只看 id 相等，焦点落到
                       -- 同号的 user 消息上时，「▶」会画在用户消息前面。
                       focused = isJust (msgTool m) && appCardFocus st == Just (msgId m)
                       fold = foldOf m
                       sel = inSel st (msgId m)
                       draw = drawMessage cfg focused fold m
                       widget = if sel then withAttr (attrName "selection") draw else draw
                   -- Retained per-message render (the ported TranscriptScrolling
                   -- contract): scrolling and typing redraw only what changed.
                   in cached (MsgCache (msgId m) (fold == FoldExpanded) focused sel) widget
                 | m <- visible ]
                   ++ maybe [] (pure . drawPending cfg) (appPending st)
  where
    cfg = appEffCfg st
    visible = filter (not . cardHidden st) (appMessages st)
    foldOf m
      | appVerbose st = FoldExpanded
      | otherwise = fromMaybe FoldCollapsed (Map.lookup (msgId m) (appFolds st))


-- | 消息是否落在拖选区间内。
--
-- 区间归一与判定在 UI.Selection.inSelRange（纯、可单测）；这里只做
-- AppState 取字段的薄封装，因为 UI.State 依赖 brick，纯模块不能反向依赖它
-- ——否则测试套件会被迫引入 brick。
inSel :: AppState -> Int -> Bool
inSel st = inSelRange (appSelStart st) (appSelEnd st)

drawInput :: AppState -> Widget ResourceName
drawInput st =
  withAttr (attrName "border") $
    borderWithLabel busyLabel $
      withAttr (attrName "input") $
        -- One row: this is a text input, not a multi-line editor (the user
        -- asked for minHeight=1; shortcuts live on Ctrl+… only).
        vLimit 1 $
          renderEditor (str . T.unpack . T.unlines) True (appInput st)
  where
    visibleRows = max 1 (min 6 (length (getEditContents (appInput st))))
    -- No timer thread: streaming deltas drive redraws, so the frame index
    -- derives from the accumulated length — it animates exactly while the
    -- reply is actually moving (a frozen spinner honestly shows a stall).
    awaitingStep = isJust (appApproval st)
                   || case appPlan st of
                        Just pv -> isJust (pvPending pv)
                        Nothing -> False
    busyLabel = case runState (appBusy st) awaitingStep of
      RunIdle -> str " Input "
      RunAwaiting ->
        withAttr (attrName "plan") $ str " ⏸ Awaiting approval… "
      RunRunning ->
        withAttr (attrName "busy") $ str $
          case appPending st of
            Just pm -> " " <> T.unpack (spinnerFrame (T.length (pmContent pm))) <> " Streaming… "
            Nothing -> " ⏳ Thinking… "

-- | Braille spinner frames 见 UI.Render.Spans.spinnerFrame。


drawPlanCard :: PlanView -> Widget ResourceName
drawPlanCard pv =
  withAttr (attrName "plan") $
    borderWithLabel (withAttr (attrName "plan") $ str " Plan ") $
      vBox $
        [ padLeftRight 1 $ withAttr (attrName "status") $
            str (T.unpack (phaseLabel (pvPhase pv)))
        ]
        ++ zipWith (\n st -> padLeftRight 1 . str . T.unpack $ renderStep pv (n, st))
                   [1 :: Int ..] (pvSteps pv)
        ++ [ padLeftRight 1 $ withAttr (attrName "status") $ str (T.unpack hints)
           | not (T.null hints) ]
  where
    phaseLabel "executing_step" = "running a step…"
    phaseLabel "planning"       = "waiting for a decision"
    phaseLabel other            = other
    hints :: Text
    hints
      | pvPhase pv == "planning" = "/approve · /skip · /reject · /abandon"
      | otherwise                = "/abandon"
    renderStep p (n, st) =
      let mark = case psvStatus st of
            "done"     -> "[x]"
            "failed"   -> "[!]"
            "skipped"  -> "[-]"
            "approved" -> "[+]"
            "rejected" -> "[r]"
            _          -> "[·]"
          here = if pvPending pv == Just (psvId st) then "  ←" else ""
      in T.pack (show (n :: Int)) <> ". " <> mark <> " " <> psvTitle st <> here

-- | 状态栏的纯文本源（statusSandboxTag / statusClock / statusModelLine /
-- statusGitLine / statusPeak / statusStatsLine …）已整体迁到
-- UI.Brick.Draw.Status。本模块只保留 Widget 装配。

-- | 统计工具（statusCommas / statusShortK / statusPct / statusOneDec /
-- statusUsable / statusCtxPct / statusTurnsSuffix）见 UI.Brick.Draw.Status。

-- | 状态栏第 2 行的统计段：缓存 / 上下文 / 压缩 / 吞吐 / token / 成本 / 余额 / 峰谷。
--
