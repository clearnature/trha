{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}

module Core.Types
  ( -- * Core Types
    SessionId
  , AgentId
  , ToolName
  , Message(..)
  , SessionEvent(..)
  , AgentState(..)
  , Tool(..)
  , ModelInfo(..)
  , Usage(..)
  , StreamChunk(..)
  
    -- * Configuration
  , CLIConfig(..)
  , defaultCLIConfig
  
    -- * Errors
  , CLIError(..)
  ) where

import Data.Aeson
import Data.Text (Text)
import GHC.Generics (Generic)

-- | Unique identifier for a session
type SessionId = String

-- | Unique identifier for an agent
type AgentId = String

-- | Unique identifier for a tool
type ToolName = String

-- | A message in the conversation
data Message = Message
  { messageRole    :: Text
  , messageContent :: Text
  } deriving (Show, Eq, Generic)

instance ToJSON Message
instance FromJSON Message

-- | Events that can occur in a session
data SessionEvent
  = UserMessage Text
  | AssistantMessage Text
  | ToolCall ToolName Text
  | ToolResult ToolName Text
  | SystemEvent Text
  deriving (Show, Eq, Generic)

instance ToJSON SessionEvent
instance FromJSON SessionEvent

-- | States of an agent
data AgentState
  = Idle
  | Processing Text
  | WaitingForTool Text
  | Completed Text
  | Error Text
  deriving (Show, Eq, Generic)

instance ToJSON AgentState
instance FromJSON AgentState

-- | A tool with its metadata
data Tool = Tool
  { toolName        :: ToolName
  , toolDescription :: Text
  , toolSchema      :: Text
  } deriving (Show, Eq, Generic)

instance ToJSON Tool
instance FromJSON Tool

-- | Model information
data ModelInfo = ModelInfo
  { modelName        :: Text
  , modelDescription :: Text
  , modelContextSize :: Int
  } deriving (Show, Eq, Generic)

instance ToJSON ModelInfo
instance FromJSON ModelInfo

-- | Usage statistics
data Usage = Usage
  { usagePromptTokens     :: Int
  , usageCompletionTokens :: Int
  , usageTotalTokens      :: Int
  } deriving (Show, Eq, Generic)

instance ToJSON Usage
instance FromJSON Usage

-- | Stream chunks from the LLM
data StreamChunk
  = ChunkDelta Text
  | ChunkToolCall ToolName [Text]
  | ChunkDone Usage
  deriving (Show, Eq, Generic)

instance ToJSON StreamChunk
instance FromJSON StreamChunk

-- | CLI configuration
data CLIConfig = CLIConfig
  { configHost       :: Text
  , configPort       :: Int
  , configModel      :: Text
  , configMaxTokens  :: Int
  , configTimeout    :: Int
  , configRetries    :: Int
  , configVerbose    :: Bool
  } deriving (Show, Eq, Generic)

instance ToJSON CLIConfig
instance FromJSON CLIConfig

-- | Default CLI configuration
defaultCLIConfig :: CLIConfig
defaultCLIConfig = CLIConfig
  { configHost      = "localhost"
  , configPort      = 3000
  , configModel     = "deepseek-chat"
  , configMaxTokens = 4096
  , configTimeout   = 30000
  , configRetries   = 3
  , configVerbose   = False
  }

-- | CLI errors
data CLIError
  = ConnectionError Text
  | AuthenticationError Text
  | ValidationError Text
  | ServerError Text
  | TimeoutError
  | ModelError Text
  | UnknownCLIError Text
  deriving (Show, Eq, Generic)

instance ToJSON CLIError
instance FromJSON CLIError