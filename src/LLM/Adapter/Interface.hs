{-# LANGUAGE OverloadedStrings #-}

module LLM.Adapter.Interface
  ( LLMAdapter(..)
  , createAdapter
  , createCPUAdapter
  ) where

import LLM.Adapter.Types
import Infrastructure.CPU.Inference
import Infrastructure.CPU.Types
import Data.Text (Text)
import qualified Data.Text as T

-- | LLM adapter interface — the core abstraction for all LLM backends
data LLMAdapter = LLMAdapter
  { llmChat   :: [Message] -> IO [StreamChunk]
  , llmEmbed  :: Text -> IO [Float]
  , llmModels :: IO [ModelInfo]
  }

-- | Create a generic adapter (echo fallback)
createAdapter :: Text -> IO LLMAdapter
createAdapter _ = do
  return $ LLMAdapter
    { llmChat = \messages -> do
        let lastMsg = if null messages then "" else messageContent (last messages)
        return [ChunkDelta $ "Echo: " <> lastMsg, ChunkDone (Usage 10 20 30)]
    , llmEmbed = \_ -> return [0.1, 0.2, 0.3]
    , llmModels = return [ModelInfo "default" "Default Model" 4096]
    }

-- | Create a CPU adapter (local inference)
createCPUAdapter :: FilePath -> IO LLMAdapter
createCPUAdapter modelPath = do
  let features = CPUFeatures
        { featureSSE = True, featureSSE2 = True, featureSSE3 = True
        , featureSSSE3 = True, featureSSE41 = True, featureSSE42 = True
        , featureAVX = True, featureAVX2 = True, featureAVX512 = False
        , featureFMA = True, featureF16C = True
        , featureNEON = False, featureSVE = False, featureSVE2 = False
        }
  let backend = CPUBackend defaultCPUConfig X86_64 features
  engine <- createInferenceEngine backend modelPath

  result <- loadModel engine
  case result of
    Left err -> error $ "Failed to load model: " ++ err
    Right () -> return ()

  return $ LLMAdapter
    { llmChat = \messages -> do
        let prompt = T.unwords $ map messageContent messages
        result <- generate engine prompt 100
        case result of
          Left err -> return [ChunkError $ T.pack err]
          Right text -> return [ChunkDelta text, ChunkDone (Usage 100 200 300)]
    , llmEmbed = \text -> do
        let tokens = tokenize engine text
        return $ map fromIntegral tokens
    , llmModels = return [ModelInfo "cpu-model" "CPU Inference Model" 4096]
    }
