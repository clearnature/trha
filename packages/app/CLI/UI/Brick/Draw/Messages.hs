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
  , drawHome
  , drawPlanCard
  , drawUI
  , drawToast
  , drawPending
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
import UI.Brick.Draw.Home (drawHome, drawPlanCard)
import UI.Brick.Draw.Input (drawInput)
import UI.Brick.Draw.MessageList
  ( cardHidden, drawMessage, drawMessages, drawPending, inSel )
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

-- | 工具卡是否折叠隐藏（verbose 模式全展开；否则看用户折叠状态）。














drawUI :: AppState -> [Widget ResourceName]
drawUI st =
  case appSettings st of
    -- /settings takes over the whole screen (qwen-style dialog): the tab
    -- bar sits at the top and the content fills the terminal.
    Just _  -> [ drawSettingsPanel st ]
    Nothing -> dialogLayer ++ [ overlayLayer, mainUI ]
  where
    -- The sidebar needs the terminal width, which only exists inside a
    -- rendering context.  Dock: share the row.  Overlay: draw the card in a
    -- separate layer translated to the right edge (the cells it does not
    -- cover stay transparent, so the conversation shows through).
    mainUI = Widget Greedy Greedy $ do
      c <- getContext
      let w = c ^. availWidthL
      case sidebarRender w (appSidebar st) of
        RenderDocked sw -> render $ vBox
          [ hBox
              [ hLimit (messageWidth w (appSidebar st)) content
              , padLeft (Pad 1) (drawSidebar st sw)
              ]
          , drawStatus st
          ]
        _ -> render (vBox [content, drawStatus st])

    overlayLayer = Widget Greedy Greedy $ do
      c <- getContext
      let w = c ^. availWidthL
      case sidebarRender w (appSidebar st) of
        RenderOverlay sw -> do
          res <- render (drawSidebar st sw)
          return $ res & imageL %~ V.translate (max 0 (w - sw)) 0
        _ -> return emptyResult

    content = vBox $
      case appRoute st of
        RouteHome ->
          [ maybe emptyWidget drawToast (appToast st)
          , drawHome st
          , drawInput st
          ]
        RouteSession ->
          [ maybe emptyWidget drawToast (appToast st)
          , drawMessages st
          , maybe emptyWidget drawPlanCard (appPlan st)
          , maybe emptyWidget drawWizard (appWizard st)
          , maybe emptyWidget (drawCompletion st) (appComp st)
          , drawInput st
          ]
    -- Brick's draw returns a layer stack: the first widget is the top
    -- layer, so an open dialog renders over the chat as a centered card
    -- (mouse clicks no longer pass through it in brick 3.0).
    dialogLayer = case stackTop (appDialogs st) of
      Just d  -> [ centerLayer (drawDialog st d) ]
      Nothing -> case appPalette st of
        -- Identical attribute to the skills dialog (which the user confirmed
        -- floats correctly): centerLayer is brick's float — transparent
        -- background, no container row taken.
        Just d  -> [ centerLayer (drawPalette d) ]
        Nothing -> []

-- | Transient notice strip above the message area (Toast).
drawToast :: (Text, UTCTime) -> Widget ResourceName
drawToast (msg, _) =
  padLeftRight 1 $
    withAttr (attrName "busy") $
      borderWithLabel (withAttr (attrName "busy") $ str " notice ") $
        padLeftRight 1 $ strWrap (T.unpack msg)

