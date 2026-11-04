{-# LANGUAGE OverloadedStrings #-}

-- | 消息体渲染：头部标记、正文（Markdown/代码块/工具卡/diff）、样式判定。
--
-- 从 "UI.Brick.Draw.Messages" 拆出。这一组只依赖 UI.Render.* 与 Brick 的
-- widget 组合，不碰 AppState 的路由/对话框，因此可以与 drawUI/drawMessages 分离。
module UI.Brick.Draw.MessageBody
  ( roleStyle, messageHeader, messageBody, renderToolBody
  , renderBlocks, diffWidget, spanWrap
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
  -- 工具轨迹是**独立行**（role == "tool"），与 Reasonix 的 ItemKind.ItemTool 同构：
  -- 分派依据是 role，而不是 msgTool 字段——后者只在 role == "tool" 时有值，
  -- 是这条行的 payload。这样「只看对话 / 只看轨迹」可以纯按 role 过滤实现。
  | role == "tool" =
      maybe emptyWidget (\card -> renderToolBody card fold) tool
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
