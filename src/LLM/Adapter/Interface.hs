{-# LANGUAGE OverloadedStrings #-}

module LLM.Adapter.Interface
  ( LLMAdapter(..)
  , createAdapter
  , createDeepSeekAdapter
  , createOpenAIAdapter
  ) where

import LLM.Adapter.Types
import Data.Text (Text)
import qualified Data.Text as T

-- | LLM adapter interface
data LLMAdapter = LLMAdapter
  { llmChat   :: [Message] -> IO [StreamChunk]
  , llmEmbed  :: Text -> IO [Float]
  , llmModels :: IO [ModelInfo]
  }

-- | Create an adapter (generic)
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

-- | Create a DeepSeek adapter
createDeepSeekAdapter :: Text -> IO LLMAdapter
createDeepSeekAdapter apiKey = do
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

-- | Create an OpenAI adapter
createOpenAIAdapter :: Text -> IO LLMAdapter
createOpenAIAdapter apiKey = do
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