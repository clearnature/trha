{-# LANGUAGE OverloadedStrings #-}

module LLM.Providers.DeepSeek
  ( createDeepSeekAdapter
  ) where

import LLM.Adapter.Types
import LLM.Adapter.Interface
import Data.Text (Text)

-- | Create a DeepSeek adapter (placeholder implementation)
createDeepSeekAdapter :: Text -> IO LLMAdapter
createDeepSeekAdapter apiKey = do
  return $ LLMAdapter
    { llmChat = \messages -> do
        -- Placeholder: in real implementation, call DeepSeek API
        return [ChunkDelta "Hello from DeepSeek!", ChunkDone (Usage 10 20 30)]
    , llmEmbed = \text -> do
        -- Placeholder: return dummy embeddings
        return [0.1, 0.2, 0.3]
    , llmModels = do
        return [ModelInfo "deepseek-chat" "DeepSeek Chat Model" 4096]
    }