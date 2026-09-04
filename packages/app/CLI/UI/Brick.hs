{-# LANGUAGE OverloadedStrings #-}

module UI.Brick
  ( -- * Brick UI
    AppState(..)
  , app
  , initialState
  , drawUI
  , handleEvent
  , runTUI
  ) where

import Brick
import Brick.BChan
import Brick.Widgets.Border
import Brick.Widgets.Center
import Brick.Widgets.Edit
import Control.Concurrent (forkIO)
import Control.Monad (void)
import Control.Monad.IO.Class (liftIO)
import Core.Types
import Bridge.Scheduler (SchedulerBridge, sendMessage, createSession, listModels)
import Data.IORef
import Data.Text (Text)
import qualified Data.Text as T
import Graphics.Vty.Attributes
import Graphics.Vty.Config (defaultConfig)
import Graphics.Vty.CrossPlatform (mkVty)
import Graphics.Vty.Input.Events

-- | Application state
data AppState = AppState
  { appMessages    :: [ChatMessage]
  , appInput       :: Editor Text ResourceName
  , appSessionId   :: Maybe SessionId
  , appModel       :: Text
  , appStatus      :: Text
  , appBridge      :: SchedulerBridge
  }

-- | Chat message
data ChatMessage = ChatMessage
  { msgRole    :: Text
  , msgContent :: Text
  } deriving (Show)

-- | Resource names
data ResourceName
  = MessageArea
  | InputArea
  deriving (Show, Eq, Ord)

-- | Create initial state
initialState :: SchedulerBridge -> Text -> AppState
initialState bridge model = AppState
  { appMessages = [ChatMessage "system" "Welcome to trha! Type a message to get started."]
  , appInput = editorText InputArea (Just 1) ""
  , appSessionId = Nothing
  , appModel = model
  , appStatus = "Ready"
  , appBridge = bridge
  }

-- | Application
app :: App AppState e ResourceName
app = App
  { appDraw = drawUI
  , appChooseCursor = showFirstCursor
  , appHandleEvent = handleEvent
  , appStartEvent = return ()
  , appAttrMap = const theMap
  }

-- | Attribute map (Tokyo Night inspired)
theMap :: AttrMap
theMap = attrMap defAttr
  [ (attrName "header", fg brightCyan `withStyle` bold)
  , (attrName "message", fg brightWhite)
  , (attrName "user", fg brightGreen)
  , (attrName "assistant", fg brightBlue)
  , (attrName "system", fg brightYellow)
  , (attrName "error", fg brightRed)
  , (attrName "input", fg brightCyan)
  , (attrName "status", fg brightBlack)
  , (attrName "border", fg brightBlack)
  , (attrName "title", fg magenta `withStyle` bold)
  ]

-- | Run the TUI
runTUI :: SchedulerBridge -> Text -> IO ()
runTUI bridge model = do
  chan <- newBChan 10
  let mkVty' = mkVty defaultConfig
  vty <- mkVty'
  let st = initialState bridge model
  void $ customMain vty mkVty' (Just chan) app st

-- | Draw UI
drawUI :: AppState -> [Widget ResourceName]
drawUI st =
  [ vBox
      [ drawHeader st
      , vLimitPercent 75 $ drawMessages st
      , drawInput st
      , drawStatus st
      ]
  ]

-- | Draw header
drawHeader :: AppState -> Widget ResourceName
drawHeader st =
  withAttr (attrName "header") $
    padAll 1 $
      hCenter $
        str "trha TUI"

-- | Draw messages
drawMessages :: AppState -> Widget ResourceName
drawMessages st =
  withAttr (attrName "border") $
    borderWithLabel (withAttr (attrName "title") $ str " Messages ") $
      viewport MessageArea Vertical $
        vBox $
          map drawMessage (appMessages st)

-- | Draw a single message
drawMessage :: ChatMessage -> Widget ResourceName
drawMessage msg =
  padLeftRight 1 $
    padTopBottom 1 $
      vBox
        [ withAttr roleAttr $ str $ "[" ++ T.unpack (msgRole msg) ++ "]"
        , padLeft (Pad 2) $ str $ T.unpack (msgContent msg)
        ]
  where
    roleAttr = case msgRole msg of
      "user"      -> attrName "user"
      "assistant" -> attrName "assistant"
      "system"    -> attrName "system"
      _           -> attrName "message"

-- | Draw input
drawInput :: AppState -> Widget ResourceName
drawInput st =
  withAttr (attrName "border") $
    borderWithLabel (str " Input (Enter to send, Ctrl+Q to quit) ") $
      withAttr (attrName "input") $
        renderEditor (str . T.unpack . T.unlines) True (appInput st)

-- | Draw status
drawStatus :: AppState -> Widget ResourceName
drawStatus st =
  withAttr (attrName "status") $
    padAll 1 $
      hBox
        [ str "Model: "
        , str $ T.unpack $ appModel st
        , str " | "
        , str $ T.unpack $ appStatus st
        , str " | Session: "
        , str $ maybe "none" id (appSessionId st)
        ]

-- | Handle events
handleEvent :: BrickEvent ResourceName e -> EventM ResourceName AppState ()
handleEvent (VtyEvent (EvKey (KChar 'q') [MCtrl])) = halt
handleEvent (VtyEvent (EvKey KEnter [])) = do
  st <- get
  let input = T.strip $ T.unlines $ getEditContents $ appInput st
  if T.null input
    then return ()
    else do
      -- Add user message
      let userMsg = ChatMessage "user" input
      put st { appMessages = appMessages st ++ [userMsg]
             , appInput = editorText InputArea (Just 1) ""
             , appStatus = "Sending..."
             }

      -- Create session if needed
      st' <- get
      session <- case appSessionId st' of
        Just sid -> return sid
        Nothing -> do
          result <- liftIO $ createSession (appBridge st')
          case result of
            Right sid -> do
              put st' { appSessionId = Just sid }
              return sid
            Left err -> do
              let errMsg = ChatMessage "system" $ "Failed to create session: " <> T.pack (show err)
              put st' { appMessages = appMessages st' ++ [errMsg]
                      , appStatus = "Error"
                      }
              return ""

      -- Send message
      if null session
        then return ()
        else do
          st'' <- get
          result <- liftIO $ sendMessage (appBridge st'') session input
          case result of
            Right chunk -> do
              let content = case chunk of
                    ChunkDelta text -> text
                    ChunkToolCall name args -> "[Tool: " <> T.pack name <> "]"
                    ChunkDone usage -> "[Done: " <> T.pack (show (usageTotalTokens usage)) <> " tokens]"
              let assistantMsg = ChatMessage "assistant" content
              put st'' { appMessages = appMessages st'' ++ [assistantMsg]
                       , appStatus = "Ready"
                       }
            Left err -> do
              let errMsg = ChatMessage "system" $ "Error: " <> T.pack (show err)
              put st'' { appMessages = appMessages st'' ++ [errMsg]
                       , appStatus = "Error"
                       }

      -- Scroll to bottom
      vScrollToEnd (viewportScroll MessageArea)

handleEvent (VtyEvent ev) = do
  st <- get
  let input = appInput st
  newInput <- nestEventM' input $ handleEditorEvent (VtyEvent ev)
  put st { appInput = newInput }
handleEvent _ = return ()
