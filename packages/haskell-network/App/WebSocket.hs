{-# LANGUAGE OverloadedStrings #-}

module App.WebSocket
  ( -- * WebSocket Application
    WebSocketApp(..)
  , createWebSocketApp
  , runWebSocketApp
  
    -- * Handlers
  , websocketHandler
  , messageHandler
  ) where

import Network.WebSockets
import Data.Text (Text)
import qualified Data.Text as T

-- | WebSocket application
data WebSocketApp = WebSocketApp
  { wsAppPort :: Int
  , wsAppHost :: String
  }

-- | Create a new WebSocket application
createWebSocketApp :: Int -> String -> WebSocketApp
createWebSocketApp port host = WebSocketApp port host

-- | Run the WebSocket application
runWebSocketApp :: WebSocketApp -> IO ()
runWebSocketApp app = do
    putStrLn $ "Starting WebSocket server on " ++ wsAppHost app ++ ":" ++ show (wsAppPort app)
    -- Placeholder: implement WebSocket server
    putStrLn "WebSocket server started"

-- | WebSocket handler
websocketHandler :: PendingConnection -> IO ()
websocketHandler pendingConn = do
    conn <- acceptRequest pendingConn
    putStrLn "WebSocket connection accepted"
    -- Placeholder: implement WebSocket handling
    sendClose conn ("Goodbye" :: Text)

-- | Message handler
messageHandler :: Connection -> Text -> IO ()
messageHandler conn message = do
    putStrLn $ "Received message: " ++ T.unpack message
    -- Placeholder: implement message handling
    sendTextData conn ("Echo: " <> message)