{-# LANGUAGE OverloadedStrings #-}

module LLM.Adapter.Interface
  ( LLMAdapter(..)
  , StreamCall
  , mkAdapter
  , blockingStream
  , createAdapter
  , createCPUAdapter
  , createCPUAdapterWith
  , cpuAdapterWithEngine
  , setEngineGPU
  , unsupportedTools
  ) where

import LLM.Adapter.Types
import Infrastructure.CPU.Inference
  ( Brain (..), InferenceEngine (..)
  , createInferenceEngine, withBrain, generate, generateStream, tokenize, loadModel )
import Infrastructure.CPU.SovereignModel (SovereignConfig(..))
import Infrastructure.CPU.SovereignWuxingLayer (WuxingConfig(..))
import Infrastructure.CPU.SovereignFull (loadWuxingFromSov)
import Infrastructure.CPU.Types
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T

-- | A streaming function-calling call: the same arguments as @llmChatTools@,
-- plus a callback that receives each increment the moment it arrives.
type StreamCall =
  [ChatMessage] -> [ToolSpec] -> (StreamChunk -> IO ()) -> IO ChatTurn

-- | LLM adapter interface — the core abstraction for all LLM backends.
--
-- Streaming is part of the interface, not a special case: a backend with a
-- real streaming path supplies it, and one without wraps its blocking call
-- (@blockingStream@).  Callers therefore never branch on "can this stream?".
data LLMAdapter = LLMAdapter
  { llmChat            :: [Message] -> IO [StreamChunk]
  , llmChatTools       :: [ChatMessage] -> [ToolSpec] -> GenParams -> IO ChatTurn
  , llmEmbed           :: Text -> IO [Float]
  , llmModels          :: IO [ModelInfo]
  , llmChatToolsStream :: StreamCall
  }

-- | The blocking call, announced as increments — the honest fallback for a
-- backend that cannot stream.  Callers still receive events, in order.
blockingStream :: ([ChatMessage] -> [ToolSpec] -> GenParams -> IO ChatTurn) -> StreamCall
blockingStream tools msgs specs onEvent = do
  turn <- tools msgs specs defaultGenParams
  onEvent (ChunkDelta (ctContent turn))
  mapM_ (\tc -> onEvent (ChunkToolCall (tcName tc) (tcArguments tc))) (ctToolCalls turn)
  case ctError turn of
    Just e  -> onEvent (ChunkError e)
    Nothing -> onEvent (ChunkDone (maybe (mkUsage 0 0 0) id (ctUsage turn)))
  pure turn

-- | Build an adapter.  Pass @Just stream@ when the backend has a real
-- streaming path; @Nothing@ fills it in with @blockingStream@.
mkAdapter
  :: ([Message] -> IO [StreamChunk])
  -> ([ChatMessage] -> [ToolSpec] -> IO ChatTurn)
  -> (Text -> IO [Float])
  -> IO [ModelInfo]
  -> Maybe StreamCall
  -> LLMAdapter
mkAdapter chat tools embed models mstream = LLMAdapter
  { llmChat = chat
  , llmChatTools = \msgs specs _gp -> tools msgs specs
  , llmEmbed = embed
  , llmModels = models
  , llmChatToolsStream = fromMaybe (blockingStream (\msgs specs _gp -> tools msgs specs)) mstream
  }

-- | The CPU engine's real stream: tokens reach the caller as they are
-- produced.  The engine samples one token at a time (see @generateStream@), so
-- this is genuine granularity, not a replay of a finished answer.
cpuStream :: InferenceEngine -> StreamCall
cpuStream engine msgs _specs onEvent = do
  let prompt = T.unwords (map chatText msgs)
  result <- generateStream engine prompt (engineMaxTokens engine) (\piece -> onEvent (ChunkDelta piece))
  case result of
    Left err -> do
      onEvent (ChunkError (T.pack err))
      pure (ChatTurn "" [] Nothing (Just (T.pack err)))
    Right text -> do
      onEvent (ChunkDone (mkUsage 100 200 300))
      pure (ChatTurn text [] (Just (mkUsage 100 200 300)) Nothing)

-- | 每轮生成的最大 token 数。占位引擎（无 Brain）保持历史值 100；
-- 真实 CPU 大脑（每 token 跑 60 层，约几分钟）用小值做「接线演示」。
engineMaxTokens :: InferenceEngine -> Int
engineMaxTokens e = case engineBrain e of
  Just _  -> 3
  Nothing -> 100

-- | The CPU engine answers as plain text: it has no tool calling, but it does
-- generate — so the blocking path goes through the same engine the streaming
-- path does, and the two agree by construction.
cpuTools :: InferenceEngine -> [ChatMessage] -> [ToolSpec] -> IO ChatTurn
cpuTools engine msgs _specs = do
  result <- generate engine (T.unwords (map chatText msgs)) (engineMaxTokens engine)
  pure $ case result of
    Left err   -> ChatTurn "" [] Nothing (Just (T.pack err))
    Right text -> ChatTurn text [] (Just (mkUsage 100 200 300)) Nothing

-- | One chat turn as plain text (the engine works on text, not roles).
chatText :: ChatMessage -> Text
chatText (ChatSystem t)      = t
chatText (ChatUser t)        = t
chatText (ChatAssistant t _) = t
chatText (ChatTool _ out)    = out

-- | Honest default for backends without function-calling support.
unsupportedTools :: [ChatMessage] -> [ToolSpec] -> IO ChatTurn
unsupportedTools _ _ =
  return $ ChatTurn "" [] Nothing (Just "tools not supported by this adapter")

-- | Create a generic adapter (echo fallback)
createAdapter :: Text -> IO LLMAdapter
createAdapter _ = return $ mkAdapter
  (\messages -> do
      let lastMsg = if null messages then "" else messageContent (last messages)
      return [ChunkDelta $ "Echo: " <> lastMsg, ChunkDone (mkUsage 10 20 30)])
  unsupportedTools
  (\_ -> return [0.1, 0.2, 0.3])
  (return [ModelInfo "default" "Default Model" 4096])
  (Just echoStream)

-- | The echo adapter's minimal stream: it has no backend to wait on, so it
-- emits as soon as it can rather than pretending to be slow.
echoStream :: StreamCall
echoStream msgs _specs onEvent = do
  let lastMsg = case reverse msgs of
        (ChatUser t : _)         -> t
        (ChatAssistant t _ : _)  -> t
        (ChatSystem t : _)       -> t
        (ChatTool _ out : _)     -> out
        []                       -> ""
      txt = "Echo: " <> lastMsg
  onEvent (ChunkDelta txt)
  onEvent (ChunkDone (mkUsage 10 20 30))
  pure (ChatTurn txt [] (Just (mkUsage 10 20 30)) Nothing)

-- | Create a CPU adapter (local inference)。返回 (engine, adapter)，
-- 上层可用 'setEngineGPU' 注入 WebGPU 前端后重建 adapter。
createCPUAdapter :: FilePath -> IO (InferenceEngine, LLMAdapter)
createCPUAdapter modelPath = createCPUAdapterWith Nothing modelPath

-- | 同上，但允许注入 WebGPU 前向工厂（纯函数句柄 → 无类型/依赖环）。
-- 工厂签名与 'sovereignForwardFullCompact' 对齐；@Nothing@ 走纯 CPU。
createCPUAdapterWith
  :: Maybe ([Int] -> IO (Either String [[Int]]))
  -> FilePath -> IO (InferenceEngine, LLMAdapter)
createCPUAdapterWith gpuFactory modelPath = do
  let features = CPUFeatures
        { featureSSE = True, featureSSE2 = True, featureSSE3 = True
        , featureSSSE3 = True, featureSSE41 = True, featureSSE42 = True
        , featureAVX = True, featureAVX2 = True, featureAVX512 = False
        , featureFMA = True, featureF16C = True
        , featureNEON = False, featureSVE = False, featureSVE2 = False
        }
  let backend = CPUBackend defaultCPUConfig X86_64 features
      -- 真实 S2Sovereign 配置（pyBitNet 锁定值）：depth=60、heads=12、vocab=1536
      realCfg = SovereignConfig { scDim = 1440, scDepth = 60, scHeads = 12
                                , scVocab = 1536, scFF = 4320, scEps = 1e-5 }
      realWcfg = WuxingConfig 1440 12 4 6 3
  engine0 <- createInferenceEngine backend modelPath
  -- 真实 wuxing 权重从 .sov 内载入；失败则回退占位引擎（不崩，提示日志）
  wlResult <- loadWuxingFromSov modelPath 12 4 3
  engine <- case wlResult of
    Left err -> do
      putStrLn $ "[cpu] 未载入 wuxing 权重（占位模式）: " ++ err
      pure (maybe id setEngineGPU gpuFactory engine0)
    Right wl -> pure $ withBrain (Brain modelPath realCfg realWcfg wl Nothing Nothing)
                    (maybe id setEngineGPU gpuFactory engine0)

  result <- loadModel engine
  case result of
    Left err -> error $ "Failed to load model: " ++ err
    Right () -> return ()

  pure (engine, cpuAdapterWithEngine engine modelPath)

-- | 注入 WebGPU 前端到 engine（返回新 engine；原始值不变）。
setEngineGPU :: ([Int] -> IO (Either String [[Int]])) -> InferenceEngine -> InferenceEngine
setEngineGPU f e = e { engineGPU = Just f }

-- | 由已建好的 engine 构造 CPU adapter（供上层注入 GPU 前端后复用逻辑）。
cpuAdapterWithEngine :: InferenceEngine -> FilePath -> LLMAdapter
cpuAdapterWithEngine engine modelPath =
  mkAdapter
    (\messages -> do
        let prompt = T.unwords $ map messageContent messages
        result <- generate engine prompt 100
        case result of
          Left err -> return [ChunkError $ T.pack err]
          Right text -> return [ChunkDelta text, ChunkDone (mkUsage 100 200 300)])
    (cpuTools engine)
    (\text -> do
        let tokens = tokenize engine text
        return $ map fromIntegral tokens)
    (return [ModelInfo "cpu-model" "CPU Inference Model" 4096])
    (Just (cpuStream engine))
