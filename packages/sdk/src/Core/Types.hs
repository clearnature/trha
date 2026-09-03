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
  , SDKConfig(..)
  , defaultConfig
  
    -- * Errors
  , SDKError(..)
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
  | ToolCall ToolName Value
  | ToolResult ToolName Value
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
  , toolSchema      :: Value
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

-- | SDK configuration
data SDKConfig = SDKConfig
  { configHost     :: Text
  , configPort     :: Int
  , configApiKey   :: Maybe Text
  , configTimeout  :: Int
  , configRetries  :: Int
  } deriving (Show, Eq, Generic)

instance ToJSON SDKConfig
instance FromJSON SDKConfig

-- | Default configuration
defaultConfig :: SDKConfig
defaultConfig = SDKConfig
  { configHost    = "localhost"
  , configPort    = 3000
  , configApiKey  = Nothing
  , configTimeout = 30
  , configRetries = 3
  }

-- | SDK errors
data SDKError
  = ConnectionError Text
  | AuthenticationError Text
  | ValidationError Text
  | ServerError Text
  | TimeoutError
  | UnknownError Text
  deriving (Show, Eq, Generic)

instance ToJSON SDKError
instance FromJSON SDKError