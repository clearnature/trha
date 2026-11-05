{-# LANGUAGE OverloadedStrings #-}

-- | 主页与计划卡：会话首页（最近会话/指令文件）与多步计划的状态卡。
--
-- 从 "UI.Brick.Draw.Messages" 拆出。
module UI.Brick.Draw.Home
  ( drawHome, drawPlanCard
  ) where

import Brick
import Brick.Widgets.Border
import Brick.Widgets.Core
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Map.Strict as Map
import qualified Graphics.Vty as V
import Lens.Micro ((&), (%~), (.~), (^.))

import Core.SessionSummary (SessionSummary(..))
import Core.Types (CLIConfig(..), PlanStepView(..), PlanView(..))
import UI.Brick.Draw.MessageList
  ( cardHidden, drawMessage, drawMessages, drawPending, inSel )
import UI.Brick.Draw.MessageBody
  ( diffWidget, messageBody, messageHeader, renderBlocks, renderToolBody
  , roleStyle, spanWrap )
import UI.Event (PendingMsg(..), Route(..), RunState(..), runState)
import UI.I18n (tr)
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

drawHome :: AppState -> Widget ResourceName
drawHome st =
  padAll 1 $
    vBox $
      [ withAttr (attrName "title") $ vBox (map str logoLines)
      , padTop (Pad 1) $ withAttr (attrName "system") $
          strWrap (T.unpack (tr (appLang st) "Type a message to start a new session, or /resume to continue one."))
      , padTop (Pad 1) $ withAttr (attrName "header") $
          str (T.unpack (tr (appLang st) "Recent sessions"))
      ]
      ++ recentLines
      ++ [ padTop (Pad 1) $ withAttr (attrName "timestamp") $
             strWrap (T.unpack (tr (appLang st) "Shift+Tab switches the permission posture; /help lists commands.")) ]
  where
    recentLines = case take 6 (appRecent st) of
      [] -> [ padLeft (Pad 2) $ withAttr (attrName "timestamp") $
                str (T.unpack (tr (appLang st) "No local sessions yet.")) ]
      xs -> [ padLeft (Pad 2) $
                hBox [ withAttr (attrName "user") (str ("• " ++ T.unpack (ssTitle s)))
                     , withAttr (attrName "timestamp") (str ("  " ++ ssId s)) ]
            | s <- xs ]
    logoLines =
      [ "  ████████╗██████╗ ██╗  ██╗ █████╗ "
      , "  ╚══██╔══╝██╔══██╗██║  ██║██╔══██╗"
      , "     ██║   ██████╔╝███████║███████║"
      , "     ██║   ██╔══██╗██╔══██║██╔══██║"
      , "     ██║   ██║  ██║██║  ██║██║  ██║"
      , "     ╚═╝   ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝"
      ]

-- | The sidebar card: Context, TODO and Session sections.
--
-- The bottom line names the two shortcuts a first-time user needs: hiding
-- the sidebar and leaving the TUI.
-- | drawSidebar 见 UI.Brick.Draw.Sidebar。
