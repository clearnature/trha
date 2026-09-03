{-# LANGUAGE OverloadedStrings #-}

module STM.Manager
  ( -- * STM Manager
    STMManager(..)
  , createSTMManager
  
    -- * STM Operations
  , atomically
  , readTVar
  , writeTVar
  , readTVarIO
  , newTVarIO
  , newTQueueIO
  , readTQueue
  , writeTQueue
  ) where

import Control.Concurrent.STM

-- | STM manager
data STMManager = STMManager
  { stmManagerName :: String
  }

-- | Create a new STM manager
createSTMManager :: IO STMManager
createSTMManager = do
  return $ STMManager "default"