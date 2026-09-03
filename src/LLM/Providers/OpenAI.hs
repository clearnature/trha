{-# LANGUAGE OverloadedStrings #-}

module LLM.Providers.OpenAI
  ( createOpenAIAdapter
  ) where

import LLM.Adapter.Types
import LLM.Adapter.Interface
import Data.Text (Text)

-- | Create an OpenAI adapter (placeholder implementation)
createOpenAIAdapter :: Text -> IO LLMAdapter
createOpenAIAdapter apiKey = do
  return $ LLMAdapter
    { llmChat = \messages -> do
        -- Placeholder: in real implementation, call OpenAI API
        return [ChunkDelta "Hello from OpenAI!", ChunkDone (Usage 10 20 30)]
    , llmEmbed = \text -> do
        -- Placeholder: return dummy embeddings
        return [0.4, 0.5, 0.6]
    , llmModels = do
        return [ModelInfo "gpt-4" "GPT-4 Model" 8192]
    }