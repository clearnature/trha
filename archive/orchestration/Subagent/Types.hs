{-# LANGUAGE OverloadedStrings #-}

module Orchestration.Subagent.Types
  ( SubAgent(..)
  , SubAgentConfig(..)
  , SubAgentState(..)
  ) where

import Data.Text (Text)

-- | Sub-agent configuration
data SubAgentConfig = SubAgentConfig
  { subAgentModel  :: Text
  , subAgentTools  :: [String]
  , subAgentTimeout :: Int
  } deriving (Show, Eq)

-- | Sub-agent state
data SubAgentState
  = SubAgentIdle
  | SubAgentRunning
  | SubAgentCompleted
  | SubAgentError String
  deriving (Show, Eq)

-- | Sub-agent instance
data SubAgent = SubAgent
  { subAgentId     :: String
  , subAgentConfig :: SubAgentConfig
  , subAgentState  :: SubAgentState
  }