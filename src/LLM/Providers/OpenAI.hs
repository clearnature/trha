{-# LANGUAGE OverloadedStrings #-}

module LLM.Providers.OpenAI
  ( createOpenAIProvider
  ) where

import LLM.Adapter.Types
import LLM.Adapter.Interface
import Data.Text (Text)

-- | Create an OpenAI provider
createOpenAIProvider :: Text -> IO LLMAdapter
createOpenAIProvider apiKey = do
  return $ LLMAdapter
    { llmChat = \messages -> do
        -- Would call OpenAI API in production
        return [ChunkDelta "Hello from OpenAI!", ChunkDone (Usage 10 20 30)]
    , llmEmbed = \text -> do
        -- Would call OpenAI embedding API
        return [0.4, 0.5, 0.6]
    , llmModels = do
        return [ModelInfo "gpt-4" "GPT-4 Model" 8192]
    }