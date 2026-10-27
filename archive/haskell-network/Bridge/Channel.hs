{-# LANGUAGE OverloadedStrings #-}

module Bridge.Channel
  ( -- * Channel Manager
    ChannelManager(..)
  , createChannelManager
  
    -- * Channel Operations
  , createChannel
  , getChannel
  , sendChannel
  , receiveChannel
  , closeChannel
  ) where

import Control.Concurrent.STM
import Data.Text (Text)

-- | Channel manager
data ChannelManager = ChannelManager
  { channelManagerName :: String
  , channels :: TVar (Map String (TQueue Dynamic))
  }

-- | Create a new channel manager
createChannelManager :: String -> IO ChannelManager
createChannelManager name = do
  channelsRef <- newTVarIO Map.empty
  return $ ChannelManager name channelsRef

-- | Create a new channel
createChannel :: ChannelManager -> String -> IO (Either String (TQueue Dynamic))
createChannel manager name = do
  channelsMap <- readTVarIO (channels manager)
  case Map.lookup name channelsMap of
    Just queue -> return $ Right queue
    Nothing -> do
      queue <- newTQueueIO
      atomically $ modifyTVar (channels manager) (Map.insert name queue)
      return $ Right queue

-- | Get a channel by name
getChannel :: ChannelManager -> String -> IO (Either String (TQueue Dynamic))
getChannel manager name = do
  channelsMap <- readTVarIO (channels manager)
  case Map.lookup name channelsMap of
    Just queue -> return $ Right queue
    Nothing -> return $ Left $ "Channel " ++ name ++ " not found"

-- | Send a message to a channel
sendChannel :: ChannelManager -> String -> Dynamic -> IO (Either String ())
sendChannel manager name message = do
  result <- getChannel manager name
  case result of
    Right queue -> do
      atomically $ writeTQueue queue message
      return $ Right ()
    Left err -> return $ Left err

-- | Receive a message from a channel
receiveChannel :: ChannelManager -> String -> IO (Either String Dynamic)
receiveChannel manager name = do
  result <- getChannel manager name
  case result of
    Right queue -> do
      message <- atomically $ readTQueue queue
      return $ Right message
    Left err -> return $ Left err

-- | Close a channel
closeChannel :: ChannelManager -> String -> IO (Either String ())
closeChannel manager name = do
  channelsMap <- readTVarIO (channels manager)
  case Map.lookup name channelsMap of
    Just _ -> do
      atomically $ modifyTVar (channels manager) (Map.delete name)
      return $ Right ()
    Nothing -> return $ Left $ "Channel " ++ name ++ " not found"