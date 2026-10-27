{-# LANGUAGE OverloadedStrings #-}

module Client.Tool
  ( -- * Tool Client
    ToolClient(..)
  , createToolClient
  
    -- * Tool Operations
  , list
  , register
  , unregister
  ) where

import Core.Types
import Core.Client
import Core.HTTP
import Data.Text (Text)

-- | Tool client
data ToolClient = ToolClient
  { toolClientSDK :: SDKClient
  }

-- | Create a new tool client
createToolClient :: SDKClient -> ToolClient
createToolClient sdk = ToolClient sdk

-- | List all tools
list :: ToolClient -> IO (Either SDKError [Tool])
list client = Core.Client.listTools (toolClientSDK client)

-- | Register a tool
register :: ToolClient -> Tool -> IO (Either SDKError ())
register client tool = Core.Client.registerTool (toolClientSDK client) tool

-- | Unregister a tool
unregister :: ToolClient -> ToolName -> IO (Either SDKError ())
unregister client toolName = Core.Client.unregisterTool (toolClientSDK client) toolName