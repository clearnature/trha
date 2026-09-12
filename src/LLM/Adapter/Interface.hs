{-# LANGUAGE OverloadedStrings #-}

module LLM.Adapter.Interface
  ( LLMAdapter(..)
  , StreamCall
  , mkAdapter
  , blockingStream
  , createAdapter
  , createCPUAdapter
  , unsupportedTools
  ) where

import LLM.Adapter.Types
import Infrastructure.CPU.Inference
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
  , llmChatTools       :: [ChatMessage] -> [ToolSpec] -> IO ChatTurn
  , llmEmbed           :: Text -> IO [Float]
  , llmModels          :: IO [ModelInfo]
  , llmChatToolsStream :: StreamCall
  }

-- | The blocking call, announced as increments — the honest fallback for a
-- backend that cannot stream.  Callers still receive events, in order.
blockingStream :: ([ChatMessage] -> [ToolSpec] -> IO ChatTurn) -> StreamCall
blockingStream tools msgs specs onEvent = do
  turn <- tools msgs specs
  onEvent (ChunkDelta (ctContent turn))
  mapM_ (\tc -> onEvent (ChunkToolCall (tcName tc) (tcArguments tc))) (ctToolCalls turn)
  case ctError turn of
    Just e  -> onEvent (ChunkError e)
    Nothing -> onEvent (ChunkDone (maybe (Usage 0 0 0) id (ctUsage turn)))
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
  , llmChatTools = tools
  , llmEmbed = embed
  , llmModels = models
  , llmChatToolsStream = fromMaybe (blockingStream tools) mstream
  }

-- | The CPU engine's real stream: tokens reach the caller as they are
-- produced.  The engine samples one token at a time (see @generateStream@), so
-- this is genuine granularity, not a replay of a finished answer.
cpuStream :: InferenceEngine -> StreamCall
cpuStream engine msgs _specs onEvent = do
  let prompt = T.unwords (map chatText msgs)
  result <- generateStream engine prompt 100 (\piece -> onEvent (ChunkDelta piece))
  case result of
    Left err -> do
      onEvent (ChunkError (T.pack err))
      pure (ChatTurn "" [] Nothing (Just (T.pack err)))
    Right text -> do
      onEvent (ChunkDone (Usage 100 200 300))
      pure (ChatTurn text [] (Just (Usage 100 200 300)) Nothing)

-- | The CPU engine answers as plain text: it has no tool calling, but it does
-- generate — so the blocking path goes through the same engine the streaming
-- path does, and the two agree by construction.
cpuTools :: InferenceEngine -> [ChatMessage] -> [ToolSpec] -> IO ChatTurn
cpuTools engine msgs _specs = do
  result <- generate engine (T.unwords (map chatText msgs)) 100
  pure $ case result of
    Left err   -> ChatTurn "" [] Nothing (Just (T.pack err))
    Right text -> ChatTurn text [] (Just (Usage 100 200 300)) Nothing

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
      return [ChunkDelta $ "Echo: " <> lastMsg, ChunkDone (Usage 10 20 30)])
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
  onEvent (ChunkDone (Usage 10 20 30))
  pure (ChatTurn txt [] (Just (Usage 10 20 30)) Nothing)

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

  return $ mkAdapter
    (\messages -> do
        let prompt = T.unwords $ map messageContent messages
        result <- generate engine prompt 100
        case result of
          Left err -> return [ChunkError $ T.pack err]
          Right text -> return [ChunkDelta text, ChunkDone (Usage 100 200 300)])
    (cpuTools engine)
    (\text -> do
        let tokens = tokenize engine text
        return $ map fromIntegral tokens)
    (return [ModelInfo "cpu-model" "CPU Inference Model" 4096])
    (Just (cpuStream engine))
