{-# LANGUAGE OverloadedStrings #-}

module LLM.Adapter.Interface
  ( LLMAdapter(..)
  , StreamCall
  , mkAdapter
  , blockingStream
  , createAdapter
  , unsupportedTools
  ) where

import LLM.Adapter.Types
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T

-- | A streaming function-calling call: the same arguments as @llmChatTools@,
-- plus a callback that receives each increment the moment it arrives.
type StreamCall =
  [ChatMessage] -> [ToolSpec] -> GenParams -> (StreamChunk -> IO ()) -> IO ChatTurn

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
blockingStream tools msgs specs gp onEvent = do
  turn <- tools msgs specs gp
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





-- | One chat turn as plain text (the engine works on text, not roles).
chatText :: ChatMessage -> Text
chatText (ChatSystem t)      = t
chatText (ChatUser t)        = t
chatText (ChatAssistant t _) = t
chatText (ChatAssistantThought t _ _ _) = t
chatText (ChatTool _ out)    = out

-- | Honest default for backends without function-calling support.
unsupportedTools :: [ChatMessage] -> [ToolSpec] -> IO ChatTurn
unsupportedTools _ _ =
  return $ ChatTurn "" [] Nothing (Just "tools not supported by this adapter") Nothing Nothing

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
echoStream msgs _specs _gp onEvent = do
  let lastMsg = case reverse msgs of
        (ChatUser t : _)         -> t
        (ChatAssistant t _ : _)  -> t
        (ChatAssistantThought t _ _ _ : _) -> t
        (ChatSystem t : _)       -> t
        (ChatTool _ out : _)     -> out
        []                       -> ""
      txt = "Echo: " <> lastMsg
  onEvent (ChunkDelta txt)
  onEvent (ChunkDone (mkUsage 10 20 30))
  pure (ChatTurn txt [] (Just (mkUsage 10 20 30)) Nothing Nothing Nothing)
