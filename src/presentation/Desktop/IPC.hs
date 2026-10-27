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
import Control.Concurrent.STM
import Control.Concurrent.Chan

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
  , channelSend :: Chan IPCMessage
  , channelRecv :: Chan IPCMessage
  }

-- | Create a new IPC channel
createIPCChannel :: Text -> IO IPCChannel
createIPCChannel name = do
  sendChan <- newChan
  recvChan <- newChan
  return $ IPCChannel name sendChan recvChan

-- | Send a message through IPC
sendMessage :: IPCChannel -> IPCMessage -> IO ()
sendMessage channel msg = do
  writeChan (channelSend channel) msg

-- | Receive a message from IPC
receiveMessage :: IPCChannel -> IO IPCMessage
receiveMessage channel = do
  readChan (channelRecv channel)