{-# LANGUAGE OverloadedStrings #-}

module LLM.Adapter.Types
  ( StreamChunk(..)
  , ModelInfo(..)
  , Usage(..)
  , Message
  ) where

import Data.Text (Text)

-- | A message in the conversation
type Message = (Text, Text)  -- (role, content)

-- | Stream chunks from the LLM
data StreamChunk
  = ChunkDelta Text
  | ChunkToolCall Text [Text]  -- tool name, arguments
  | ChunkDone Usage
  deriving (Show, Eq)

-- | Model information
data ModelInfo = ModelInfo
  { modelName        :: Text
  , modelDescription :: Text
  , modelContextSize :: Int
  } deriving (Show, Eq)

-- | Usage statistics
data Usage = Usage
  { usagePromptTokens     :: Int
  , usageCompletionTokens :: Int
  , usageTotalTokens      :: Int
  } deriving (Show, Eq)