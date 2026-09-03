{-# LANGUAGE OverloadedStrings #-}

module Client.Agent
  ( -- * Agent Client
    AgentClient(..)
  , createAgentClient
  
    -- * Agent Operations
  , getState
  , updateState
  ) where

import Core.Types
import Core.Client
import Core.HTTP
import Data.Text (Text)

-- | Agent client
data AgentClient = AgentClient
  { agentClientSDK :: SDKClient
  }

-- | Create a new agent client
createAgentClient :: SDKClient -> AgentClient
createAgentClient sdk = AgentClient sdk

-- | Get agent state
getState :: AgentClient -> AgentId -> IO (Either SDKError AgentState)
getState client agentId = getAgentState (agentClientSDK client) agentId

-- | Update agent state
updateState :: AgentClient -> AgentId -> AgentState -> IO (Either SDKError ())
updateState client agentId state = updateAgentState (agentClientSDK client) agentId state