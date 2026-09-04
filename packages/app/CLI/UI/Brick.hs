{-# LANGUAGE OverloadedStrings #-}

module UI.Brick
  ( -- * Brick UI
    AppState(..)
  , ChatMessage(..)
  , AppEvent(..)
  , ResourceName(..)
  , app
  , initialState
  , runTUI
  ) where

import Brick
import Brick.BChan
import Brick.Widgets.Border
import Brick.Widgets.Edit
import Control.Concurrent.Async (async)
import Control.Monad (void)
import Control.Monad.IO.Class (liftIO)
import Core.Types
import Bridge.Scheduler
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format (formatTime, defaultTimeLocale)
import Graphics.Vty.Attributes
import Graphics.Vty.Config (defaultConfig)
import Graphics.Vty.CrossPlatform (mkVty)
import Graphics.Vty.Input.Events

-- | Application state
data AppState = AppState
  { appMessages  :: [ChatMessage]
  , appInput     :: Editor Text ResourceName
  , appSessionId :: Maybe SessionId
  , appModel     :: Text
  , appStatus    :: Text
  , appBusy      :: Bool          -- ^ True while awaiting a response
  , appBridge    :: SchedulerBridge
  , appChan      :: BChan AppEvent
  }

-- | Chat message with timestamp
data ChatMessage = ChatMessage
  { msgRole    :: Text
  , msgContent :: Text
  , msgTime    :: Text
  } deriving (Show)

-- | Async events pushed by background threads
data AppEvent
  = EvResponse (Either CLIError StreamChunk)
  | EvSession (Either CLIError SessionId)
  deriving (Show)

-- | Resource names
data ResourceName
  = MessageArea
  | InputArea
  deriving (Show, Eq, Ord)

-- | Create initial state
initialState :: SchedulerBridge -> BChan AppEvent -> Text -> AppState
initialState bridge chan model = AppState
  { appMessages  = []
  , appInput     = editorText InputArea (Just 1) ""
  , appSessionId = Nothing
  , appModel     = model
  , appStatus    = "Ready"
  , appBusy      = False
  , appBridge    = bridge
  , appChan      = chan
  }

-- | Application
app :: App AppState AppEvent ResourceName
app = App
  { appDraw         = drawUI
  , appChooseCursor = showFirstCursor
  , appHandleEvent  = handleEvent
  , appStartEvent   = return ()
  , appAttrMap      = const theMap
  }

-- | Attribute map (Tokyo Night inspired)
theMap :: AttrMap
theMap = attrMap defAttr
  [ (attrName "header",    fg brightCyan `withStyle` bold)
  , (attrName "user",      fg brightGreen `withStyle` bold)
  , (attrName "assistant", fg brightBlue)
  , (attrName "system",    fg yellow)
  , (attrName "error",     fg brightRed `withStyle` bold)
  , (attrName "input",     fg brightCyan)
  , (attrName "status",    fg brightBlack)
  , (attrName "timestamp", fg brightBlack)
  , (attrName "border",    fg brightBlack)
  , (attrName "title",     fg magenta `withStyle` bold)
  , (attrName "busy",      fg yellow `withStyle` bold)
  ]

-- | Run the TUI
runTUI :: SchedulerBridge -> Text -> IO ()
runTUI bridge model = do
  chan <- newBChan 20
  let mkVty' = mkVty defaultConfig
  vty <- mkVty'
  void $ customMain vty mkVty' (Just chan) app (initialState bridge chan model)

--------------------------------------------------------------------------------
-- Drawing
--------------------------------------------------------------------------------

drawUI :: AppState -> [Widget ResourceName]
drawUI st =
  [ vBox
      [ drawHeader
      , vLimitPercent 75 $ drawMessages st
      , drawInput st
      , drawStatus st
      ]
  ]

drawHeader :: Widget ResourceName
drawHeader =
  withAttr (attrName "header") $
    padLeftRight 1 $
      hBox [ str " trha ", str "— agent harness" ]

drawMessages :: AppState -> Widget ResourceName
drawMessages st =
  withAttr (attrName "border") $
    borderWithLabel (withAttr (attrName "title") $ str " Messages ") $
      viewport MessageArea Vertical $
        vBox $
          if null (appMessages st)
            then [ padAll 1 $ withAttr (attrName "timestamp") $
                     strWrap "No messages yet. Type something and press Enter, or /help for commands." ]
            else map drawMessage (appMessages st)

drawMessage :: ChatMessage -> Widget ResourceName
drawMessage msg =
  padLeftRight 1 $
    padTopBottom 1 $
      vBox
        [ hBox
            [ withAttr roleAttr $ str $ "[" ++ T.unpack (msgRole msg) ++ "]"
            , str " "
            , withAttr (attrName "timestamp") $ str $ T.unpack (msgTime msg)
            ]
        , padLeft (Pad 2) $ strWrap (T.unpack (msgContent msg))
        ]
  where
    roleAttr = case msgRole msg of
      "user"      -> attrName "user"
      "assistant" -> attrName "assistant"
      "system"    -> attrName "system"
      "error"     -> attrName "error"
      _           -> attrName "header"

drawInput :: AppState -> Widget ResourceName
drawInput st =
  withAttr (attrName "border") $
    borderWithLabel busyLabel $
      withAttr (attrName "input") $
        renderEditor (str . T.unpack . T.unlines) True (appInput st)
  where
    busyLabel
      | appBusy st = withAttr (attrName "busy") $ str " ⏳ Thinking… "
      | otherwise  = str " Input "

drawStatus :: AppState -> Widget ResourceName
drawStatus st =
  withAttr (attrName "status") $
    padLeftRight 1 $
      hBox
        [ str " Model: "
        , withAttr (attrName "title") $ txt (appModel st)
        , str "  │  Session: "
        , str (maybe "none" id (appSessionId st))
        , str "  │  "
        , str (T.unpack (appStatus st))
        , str "  │  PgUp/PgDn scroll · g/G top/bottom · Ctrl+Q quit"
        ]

--------------------------------------------------------------------------------
-- Event handling
--------------------------------------------------------------------------------

now :: IO Text
now = T.pack . formatTime defaultTimeLocale "%H:%M:%S" <$> getCurrentTime

appendMsg :: ChatMessage -> EventM ResourceName AppState ()
appendMsg msg = modify $ \st -> st { appMessages = appMessages st ++ [msg] }

scrollBottom :: EventM ResourceName AppState ()
scrollBottom = vScrollToEnd (viewportScroll MessageArea)

handleEvent :: BrickEvent ResourceName AppEvent -> EventM ResourceName AppState ()
handleEvent (AppEvent ev) = handleAppEvent ev
handleEvent (VtyEvent (EvKey (KChar 'q') [MCtrl])) = halt
handleEvent (VtyEvent (EvKey (KChar 'c') [MCtrl])) = halt

handleEvent (VtyEvent (EvKey KPageUp [])) =
  vScrollBy (viewportScroll MessageArea) (-10)
handleEvent (VtyEvent (EvKey KPageDown [])) =
  vScrollBy (viewportScroll MessageArea) 10
handleEvent (VtyEvent (EvKey (KChar 'g') [])) =
  vScrollToBeginning (viewportScroll MessageArea)
handleEvent (VtyEvent (EvKey (KChar 'G') [])) =
  scrollBottom

handleEvent (VtyEvent (EvKey KEnter [])) = do
  st <- get
  let input = T.strip $ T.unlines $ getEditContents $ appInput st
  if T.null input || appBusy st
    then return ()
    else do
      modify $ \s -> s { appInput = editorText InputArea (Just 1) "" }
      handleSubmit input

handleEvent (VtyEvent ev) = do
  st <- get
  newInput <- nestEventM' (appInput st) $ handleEditorEvent (VtyEvent ev)
  put st { appInput = newInput }
handleEvent _ = return ()

-- | Async events from background workers
handleAppEvent :: AppEvent -> EventM ResourceName AppState ()
handleAppEvent (EvSession result) = do
  t <- liftIO now
  case result of
    Right sid -> do
      modify $ \st -> st { appSessionId = Just sid, appStatus = "Ready" }
      appendMsg (ChatMessage "system" ("Session ready: " <> T.pack sid) t)
    Left err -> do
      appendMsg (ChatMessage "error" ("Session failed: " <> T.pack (show err)) t)
      modify $ \st -> st { appStatus = "Error", appBusy = False }
  scrollBottom
handleAppEvent (EvResponse result) = do
  t <- liftIO now
  case result of
    Right chunk -> do
      let content = case chunk of
            ChunkDelta text    -> text
            ChunkToolCall n as -> "[Tool: " <> T.pack n <> " " <> T.unwords as <> "]"
            ChunkDone usage    -> "✓ " <> T.pack (show (usageTotalTokens usage)) <> " tokens"
      appendMsg (ChatMessage "assistant" content t)
      modify $ \st -> st { appStatus = "Ready", appBusy = False }
    Left err -> do
      appendMsg (ChatMessage "error" (T.pack (show err)) t)
      modify $ \st -> st { appStatus = "Error", appBusy = False }
  scrollBottom

-- | Dispatch submitted input
handleSubmit :: Text -> EventM ResourceName AppState ()
handleSubmit input
  | "/" `T.isPrefixOf` input = handleSlash input
  | otherwise                = handleChat input

handleSlash :: Text -> EventM ResourceName AppState ()
handleSlash input = do
  t <- liftIO now
  st <- get
  let cmd = T.toLower input
  case cmd of
    "/help" ->
      appendMsg (ChatMessage "system" helpText t)
    "/clear" ->
      modify $ \s -> s { appMessages = [] }
    "/new" -> do
      modify $ \s -> s { appBusy = True, appStatus = "Creating session..." }
      void $ liftIO $ async $
        createSession (appBridge st) >>= writeBChan (appChan st) . EvSession
    "/quit" -> halt
    "/exit" -> halt
    _
      | cmd == "/model" ->
          appendMsg (ChatMessage "system" ("Current model: " <> appModel st) t)
      | "/model " `T.isPrefixOf` cmd -> do
          let model = T.strip (T.drop 7 input)
          modify $ \s -> s { appModel = model }
          appendMsg (ChatMessage "system" ("Model set: " <> model) t)
      | otherwise ->
          appendMsg (ChatMessage "system" ("Unknown command: " <> input <> " — try /help") t)
  scrollBottom
  where
    helpText = T.unlines
      [ "Commands:"
      , "  /help            Show this help"
      , "  /model [name]    Show or set the model"
      , "  /new             Create a new session"
      , "  /clear           Clear message history"
      , "  /quit            Exit (also Ctrl+Q)"
      , "Keys:"
      , "  PgUp / PgDn      Scroll messages"
      , "  g / G            Jump to top / bottom"
      , "  Ctrl+Q           Quit"
      ]

-- | Send a chat message: create session lazily, send async, never block UI
handleChat :: Text -> EventM ResourceName AppState ()
handleChat input = do
  t <- liftIO now
  appendMsg (ChatMessage "user" input t)
  modify $ \st -> st { appBusy = True, appStatus = "Thinking..." }

  st <- get
  let bridge = appBridge st
      chan   = appChan st
  void $ liftIO $ async $ case appSessionId st of
    Just sid ->
      sendMessage bridge sid input >>= writeBChan chan . EvResponse
    Nothing -> do
      sessResult <- createSession bridge
      writeBChan chan (EvSession sessResult)
      case sessResult of
        Right sid ->
          sendMessage bridge sid input >>= writeBChan chan . EvResponse
        Left _ ->
          return ()
  scrollBottom
