{-# LANGUAGE OverloadedStrings #-}

module LLM.Providers.DeepSeek
  ( createDeepSeekProvider
  ) where

import LLM.Adapter.Types
import LLM.Adapter.Interface
import Data.Text (Text)

-- | Create a DeepSeek provider
createDeepSeekProvider :: Text -> IO LLMAdapter
createDeepSeekProvider apiKey = do
  return $ LLMAdapter
    { llmChat = \messages -> do
        -- Would call DeepSeek API in production
        return [ChunkDelta "Hello from DeepSeek!", ChunkDone (Usage 10 20 30)]
    , llmEmbed = \text -> do
        -- Would call DeepSeek embedding API
        return [0.1, 0.2, 0.3]
    , llmModels = do
        return [ModelInfo "deepseek-chat" "DeepSeek Chat Model" 4096]
    }