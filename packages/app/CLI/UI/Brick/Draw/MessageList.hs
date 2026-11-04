{-# LANGUAGE OverloadedStrings #-}

-- | 消息区绘制：单条消息、待发消息、整列消息，以及卡片可见性与选区判定。
--
-- 从 "UI.Brick.Draw.Messages" 拆出。这一组决定「消息列表长什么样」，
-- 与 drawUI（按路由选面板）和 drawInput（输入区）互不依赖。
module UI.Brick.Draw.MessageList
  ( cardHidden, drawMessage, drawPending, drawMessages, inSel
  ) where

import Brick
import Brick.Widgets.Border
import Brick.Widgets.Center (centerLayer)
import Brick.Widgets.Core
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (UTCTime)
import qualified Data.Map.Strict as Map
import qualified Graphics.Vty as V
import Lens.Micro ((&), (%~), (.~), (^.))

import Core.SessionSummary (SessionSummary(..))
import Core.Types (CLIConfig(..), PlanStepView(..), PlanView(..))
import Brick.Widgets.Edit (getEditContents, renderEditor)
import UI.Brick.Draw.Dialog (drawDialog, drawPalette, drawWizard)
import UI.Brick.Draw.MessageBody
  ( diffWidget, messageBody, messageHeader, renderBlocks, renderToolBody
  , roleStyle, spanWrap )
import UI.Brick.Draw.Settings (drawSettingsPanel)
import UI.Brick.Draw.Sidebar (drawCompletion, drawSidebar)
import UI.Brick.Draw.Status (drawStatus)
import UI.Dialog (stackTop)
import UI.Event (PendingMsg(..), Route(..), RunState(..), runState)
import UI.I18n (tr)
import UI.Layout (SidebarRender(..), messageWidth, sidebarRender)
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

cardHidden :: AppState -> ChatMessage -> Bool
cardHidden st m
  | appVerbose st = False
  | Map.lookup (msgId m) (appFolds st) == Just FoldExpanded = False
  | otherwise = maybe False shouldHideTool (msgTool m)

-- | 消息角色的显示样式：(属性, 括号标签)。
--
-- 错误按种类分类，让限流显示成限流而不是笼统失败（MiMo 的 @errorKind()@）。

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
