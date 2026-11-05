{-# LANGUAGE OverloadedStrings #-}

-- | 输入区渲染：一行高的编辑器、忙时标签、等待审批/计划时的提示。
--
-- 从 "UI.Brick.Draw.Messages" 拆出。它直接读 appInput/appApproval/appPlan，
-- 与消息列表、状态栏都无耦合。
module UI.Brick.Draw.Input
  ( drawInput
  ) where

import Brick
import Brick.Widgets.Border
import Brick.Widgets.Core
import Data.Maybe (isJust)
import qualified Data.Text as T
import qualified Data.Map.Strict as Map
import qualified Graphics.Vty as V
import Lens.Micro ((&), (%~), (.~), (^.))

import Core.SessionSummary (SessionSummary(..))
import Core.Types (CLIConfig(..), PlanStepView(..), PlanView(..))
import Brick.Widgets.Edit (getEditContents, renderEditor)
import UI.Brick.Draw.MessageList
  ( cardHidden, drawMessage, drawMessages, drawPending, inSel )
import UI.Brick.Draw.MessageBody
  ( diffWidget, messageBody, messageHeader, renderBlocks, renderToolBody
  , roleStyle, spanWrap )
import UI.Event (PendingMsg(..), Route(..), RunState(..), runState)
import UI.Layout (SidebarRender(..), messageWidth, sidebarRender)
import UI.Render.Diff
  ( DiffClass(..), DiffLayout(..), DiffRow(..), diffClass, diffLayout
  , looksLikeDiff, numberDiff, renderDiffRow )
import UI.Render.Markdown (MdBlock(..), MdSpan(..), parseMarkdown)
import UI.Render.Spans
  ( SpanTok(..), diffAttrOf, fillLines, spanToks, spinnerFrame, truncLine )
import UI.Render.ToolCard
  ( ToolCard, ToolFold(..), tcDur, tcOutput, tcStatus, toolStatusLine )
import UI.Render.ToolSummary
  ( presentCard, shouldHideTool, toolDetailLines, toolHeadline )
import UI.State (AppState(..), ChatMessage(..), ResourceName(..))

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
