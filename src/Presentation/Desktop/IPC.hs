{-# LANGUAGE OverloadedStrings #-}

module Presentation.Desktop.IPC
  ( IPCMessage(..)
  , IPCChannel
  , createIPCChannel
  , sendMessage
  , receiveMessage
  ) where

import Data.Text (Text)
import Data.Dynamic

-- | IPC message types
data IPCMessage
  = IPCQuery Text
  | IPCResponse Text
  | IPCError Text
  | IPCEvent Text Dynamic
  deriving (Show)

-- | IPC channel
data IPCChannel = IPCChannel
  { channelName :: Text
  }

-- | Create a new IPC channel
createIPCChannel :: Text -> IO IPCChannel
createIPCChannel name = do
  return $ IPCChannel name

-- | Send a message through IPC (placeholder)
sendMessage :: IPCChannel -> IPCMessage -> IO ()
sendMessage channel msg = do
  putStrLn $ "Sending IPC message on channel: " ++ show (channelName channel)
  putStrLn $ "Message: " ++ show msg

-- | Receive a message from IPC (placeholder)
receiveMessage :: IPCChannel -> IO IPCMessage
receiveMessage channel = do
  putStrLn $ "Receiving IPC message from channel: " ++ show (channelName channel)
  return $ IPCResponse "Received message"