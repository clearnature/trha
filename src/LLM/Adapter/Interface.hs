{-# LANGUAGE OverloadedStrings #-}

module LLM.Adapter.Interface
  ( LLMAdapter(..)
  , createAdapter
  ) where

import LLM.Adapter.Types
import Data.Text (Text)

-- | LLM adapter interface
data LLMAdapter = LLMAdapter
  { llmChat   :: [Message] -> IO [StreamChunk]
  , llmEmbed  :: Text -> IO [Float]
  , llmModels :: IO [ModelInfo]
  }

-- | Create an adapter (placeholder)
createAdapter :: Text -> IO LLMAdapter
createAdapter apiKey = do
  return $ LLMAdapter
    { llmChat = \messages -> do
        return [ChunkDelta "Hello from adapter!", ChunkDone (Usage 10 20 30)]
    , llmEmbed = \text -> do
        return [0.1, 0.2, 0.3]
    , llmModels = do
        return [ModelInfo "default" "Default Model" 4096]
    }