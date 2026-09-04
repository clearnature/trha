{-# LANGUAGE OverloadedStrings #-}

module LLM.Adapter.Types
  ( Message(..)
  , StreamChunk(..)
  , ModelInfo(..)
  , Usage(..)
  , Role(..)
  ) where

import Data.Text (Text)
import Data.Aeson

-- | Message role
data Role = System | User | Assistant
  deriving (Show, Eq)

instance ToJSON Role where
  toJSON System    = String "system"
  toJSON User      = String "user"
  toJSON Assistant = String "assistant"

instance FromJSON Role where
  parseJSON (String "system")    = pure System
  parseJSON (String "user")      = pure User
  parseJSON (String "assistant") = pure Assistant
  parseJSON _                    = fail "Invalid role"

-- | A message in the conversation
data Message = Message
  { messageRole    :: Role
  , messageContent :: Text
  } deriving (Show, Eq)

instance ToJSON Message where
  toJSON m = object
    [ "role"    .= messageRole m
    , "content" .= messageContent m
    ]

instance FromJSON Message where
  parseJSON = withObject "Message" $ \v ->
    Message <$> v .: "role" <*> v .: "content"

-- | Stream chunks from the LLM
data StreamChunk
  = ChunkDelta Text           -- ^ Partial text content
  | ChunkToolCall Text Text   -- ^ Tool call (name, arguments JSON)
  | ChunkDone Usage           -- ^ Stream complete with usage stats
  | ChunkError Text           -- ^ Error during streaming
  deriving (Show, Eq)

-- | Model information
data ModelInfo = ModelInfo
  { modelName        :: Text
  , modelDescription :: Text
  , modelContextSize :: Int
  } deriving (Show, Eq)

instance ToJSON ModelInfo where
  toJSON m = object
    [ "id"           .= modelName m
    , "object"       .= ("model" :: Text)
    , "created"      .= (0 :: Int)
    , "owned_by"     .= ("gh-harness" :: Text)
    , "description"  .= modelDescription m
    , "context_size" .= modelContextSize m
    ]

-- | Usage statistics
data Usage = Usage
  { usagePromptTokens     :: Int
  , usageCompletionTokens :: Int
  , usageTotalTokens      :: Int
  } deriving (Show, Eq)

instance ToJSON Usage where
  toJSON u = object
    [ "prompt_tokens"     .= usagePromptTokens u
    , "completion_tokens" .= usageCompletionTokens u
    , "total_tokens"      .= usageTotalTokens u
    ]
