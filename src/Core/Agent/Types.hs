{-# LANGUAGE OverloadedStrings #-}

module Core.Agent.Types
  ( Agent(..)
  , AgentState(..)
  , AgentId
  , StepId
  , ToolCallId
  , ErrorType(..)
  , Message(..)
  , Result(..)
  , AgentConfig(..)
  ) where

import Control.Concurrent.STM
import Data.Text (Text)

-- | Unique identifier for an agent
type AgentId = String

-- | Unique identifier for a step
type StepId = String

-- | Unique identifier for a tool call
type ToolCallId = String

-- | Error types that can occur
data ErrorType
  = ToolError String
  | LLMError String
  | TimeoutError
  | InterruptedError
  deriving (Show, Eq)

-- | A message in the conversation
data Message = Message
  { messageRole    :: Text
  , messageContent :: Text
  } deriving (Show, Eq)

-- | Result of an agent run
data Result = Result
  { resultText   :: Text
  , resultTokens :: Int
  } deriving (Show, Eq)

-- | States of an agent
data AgentState
  = Idle
  | Processing StepId
  | WaitingForTool ToolCallId
  | Completed Result
  | Error ErrorType
  deriving (Show, Eq)

-- | Agent configuration
data AgentConfig = AgentConfig
  { configModel    :: Text
  , configMaxSteps :: Int
  , configTimeout  :: Int
  } deriving (Show, Eq)

-- | An agent with its state and inbox
data Agent = Agent
  { agentId     :: AgentId
  , agentState  :: TVar AgentState
  , agentInbox  :: TQueue Message
  , agentConfig :: AgentConfig
  }