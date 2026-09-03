{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

module UI.Brick
  ( -- * Brick UI
    AppState(..)
  , app
  , initialState
  , drawUI
  , handleEvent
  ) where

import Brick
import Brick.BChan
import Brick.Forms
import Brick.Widgets.Border
import Brick.Widgets.Center
import Brick.Widgets.Edit
import Control.Monad (void)
import Control.Monad.IO.Class (liftIO)
import Data.Text (Text)
import qualified Data.Text as T
import Graphics.Vty.Attributes
import Graphics.Vty.Input.Events

-- | Application state
data AppState = AppState
  { appMessages    :: [Message]
  , appInput       :: Editor Text ResourceName
  , appSessionId   :: Maybe String
  , appModel       :: Text
  , appStatus      :: Text
  } deriving (Show)

-- | Message type
data Message = Message
  { messageRole    :: Text
  , messageContent :: Text
  } deriving (Show)

-- | Resource names
data ResourceName
  = MessageArea
  | InputArea
  | StatusBar
  deriving (Show, Eq, Ord)

-- | Initial state
initialState :: AppState
initialState = AppState
  { appMessages = []
  , appInput = editorText InputArea (Just 1) ""
  , appSessionId = Nothing
  , appModel = "deepseek-chat"
  , appStatus = "Ready"
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

-- | Attribute map
theMap :: AttrMap
theMap = attrMap defAttr
  [ (attrName "message", fg brightWhite)
  , (attrName "input", fg brightCyan)
  , (attrName "status", fg brightGreen)
  , (attrName "error", fg brightRed)
  ]

-- | Draw UI
drawUI :: AppState -> [Widget ResourceName]
drawUI st =
  [ vBox
      [ drawHeader st
      , drawMessages st
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
        str "gh-harness CLI"

-- | Draw messages
drawMessages :: AppState -> Widget ResourceName
drawMessages st =
  borderWithLabel (str "Messages") $
    vLimit 20 $
      viewport MessageArea Vertical $
        vBox $
          map drawMessage (appMessages st)

-- | Draw a single message
drawMessage :: Message -> Widget ResourceName
drawMessage msg =
  padAll 1 $
    hBox
      [ withAttr (attrName "role") $
          str $ T.unpack $ messageRole msg
      , str ": "
      , withAttr (attrName "message") $
          str $ T.unpack $ messageContent msg
      ]

-- | Draw input
drawInput :: AppState -> Widget ResourceName
drawInput st =
  borderWithLabel (str "Input") $
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
        ]

-- | Handle events
handleEvent :: BrickEvent ResourceName e -> EventM ResourceName AppState ()
handleEvent (VtyEvent (EvKey (KChar 'q') [MCtrl])) = halt
handleEvent (VtyEvent (EvKey KEnter [])) = do
  st <- get
  let input = T.unlines $ getEditContents $ appInput st
  if T.null (T.strip input)
    then return ()
    else do
      let newMsg = Message "user" (T.strip input)
      put st { appMessages = appMessages st ++ [newMsg]
             , appInput = editorText InputArea (Just 1) ""
             , appStatus = "Processing..."
             }
      -- TODO: Send message to backend
      return ()
handleEvent (VtyEvent ev) = do
  st <- get
  let input = appInput st
  newInput <- handleEditorEvent ev input
  put st { appInput = newInput }
handleEvent _ = return ()