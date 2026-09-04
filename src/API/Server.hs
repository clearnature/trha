{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Haskell API Server with OpenAI, Anthropic, and Responses protocol support.
-- Includes both non-streaming and streaming (SSE) endpoints.
module API.Server
  ( startServer
  , API
  ) where

import Servant
import Network.Wai.Handler.Warp (run)
import Control.Monad.IO.Class (liftIO)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Vector as V
import Data.Aeson
import Data.Aeson.Types (parseMaybe)
import GHC.Generics
import qualified Data.Map as Map
import Control.Concurrent.STM
import Data.IORef

-- Core modules
import Core.Session.Types
import Core.Session.Manager
import Core.Agent.Modes

-- LLM modules
import qualified LLM.Adapter.Types as LLM
import LLM.Adapter.Interface (LLMAdapter(..))
import qualified LLM.Stream as Stream

--------------------------------------------------------------------------------
-- 1. Full API type: custom + OpenAI + Anthropic + Responses (stream + non-stream)
--------------------------------------------------------------------------------

type API =
  -- Custom API
       "health" :> Get '[JSON] Value
  :<|> "session" :> "start" :> ReqBody '[JSON] StartReq :> Post '[JSON] Value
  :<|> "agent" :> "step" :> ReqBody '[JSON] StepReq :> Post '[JSON] Value
  -- OpenAI compatible (non-stream)
  :<|> "v1" :> "models" :> Get '[JSON] Value
  :<|> "v1" :> "chat" :> "completions" :> ReqBody '[JSON] Value :> Post '[JSON] Value
  -- Anthropic compatible (non-stream)
  :<|> "v1" :> "messages" :> ReqBody '[JSON] Value :> Post '[JSON] Value
  -- Responses API (non-stream)
  :<|> "v1" :> "responses" :> ReqBody '[JSON] Value :> Post '[JSON] Value
  -- Streaming endpoints (SSE) - returns raw WAI Application
  :<|> "v1" :> "chat" :> "completions" :> "stream" :> ReqBody '[JSON] Value :> Post '[JSON] Value
  :<|> "v1" :> "messages" :> "stream" :> ReqBody '[JSON] Value :> Post '[JSON] Value
  :<|> "v1" :> "responses" :> "stream" :> ReqBody '[JSON] Value :> Post '[JSON] Value

-- Request types
data StartReq = StartReq { srMode :: Maybe Text }
  deriving (Generic, FromJSON)

data StepReq = StepReq { srSessionId :: Text, srMessage :: Text }
  deriving (Generic, FromJSON)

--------------------------------------------------------------------------------
-- 2. Server implementation
--------------------------------------------------------------------------------

server :: LLMAdapter -> TVar (Map.Map Text Session) -> Server API
server adapter sessions =
       healthHandler
  :<|> startSessionHandler sessions
  :<|> agentStepHandler adapter sessions
  :<|> openaiModelsHandler adapter
  :<|> openaiChatHandler adapter
  :<|> anthropicMessagesHandler adapter
  :<|> responsesHandler adapter
  :<|> openaiStreamHandler adapter
  :<|> anthropicStreamHandler adapter
  :<|> responsesStreamHandler adapter

-- Health check
healthHandler :: Handler Value
healthHandler = return $ object
  [ "status"  .= ("ok" :: Text)
  , "version" .= ("0.1.0" :: Text)
  , "modes"   .= map modeToText [minBound..(maxBound :: AgentMode)]
  ]

-- Start session
startSessionHandler :: TVar (Map.Map Text Session) -> StartReq -> Handler Value
startSessionHandler sessionsVar req = do
  let mode = maybe "standard" id (srMode req)
  session <- liftIO $ createSession ("session-" <> T.unpack mode)
  let sid = T.pack (sessionId session)
  liftIO $ atomically $ modifyTVar sessionsVar (Map.insert sid session)
  return $ object ["sessionId" .= sid, "mode" .= mode]

-- Agent step
agentStepHandler :: LLMAdapter -> TVar (Map.Map Text Session) -> StepReq -> Handler Value
agentStepHandler adapter sessionsVar req = do
  sessions <- liftIO $ readTVarIO sessionsVar
  case Map.lookup (srSessionId req) sessions of
    Nothing -> throwError err404 { errBody = "Session not found" }
    Just _ -> do
      let userMsg = LLM.Message LLM.User (srMessage req)
      chunks <- liftIO $ llmChat adapter [userMsg]
      let reply = T.concat [t | LLM.ChunkDelta t <- chunks]
      let usage = case [u | LLM.ChunkDone u <- chunks] of
            (u:_) -> u
            []    -> LLM.Usage 0 0 0
      return $ object
        [ "reply" .= reply
        , "usage" .= toJSON usage
        ]

--------------------------------------------------------------------------------
-- 3. OpenAI Compatible API
--------------------------------------------------------------------------------

openaiModelsHandler :: LLMAdapter -> Handler Value
openaiModelsHandler adapter = do
  modelList <- liftIO $ llmModels adapter
  return $ object
    [ "object" .= ("list" :: Text)
    , "data"   .= map toOpenAIModel modelList
    ]
  where
    toOpenAIModel m = object
      [ "id"           .= LLM.modelName m
      , "object"       .= ("model" :: Text)
      , "created"      .= (0 :: Int)
      , "owned_by"     .= ("gh-harness" :: Text)
      , "description"  .= LLM.modelDescription m
      , "context_size" .= LLM.modelContextSize m
      ]

openaiChatHandler :: LLMAdapter -> Value -> Handler Value
openaiChatHandler adapter body =
  case parseOpenAI body of
    Nothing -> throwError err400 { errBody = "Invalid request" }
    Just (model, msgs, _stream) -> do
      let hsMsgs = map (\(r, c) -> LLM.Message (toRole r) c) msgs
      chunks <- liftIO $ llmChat adapter hsMsgs
      let content = T.concat [t | LLM.ChunkDelta t <- chunks]
      let usage = case [u | LLM.ChunkDone u <- chunks] of
            (u:_) -> u
            []    -> LLM.Usage 0 0 0
      return $ object
        [ "id"      .= ("chatcmpl-" <> model :: Text)
        , "object"  .= ("chat.completion" :: Text)
        , "model"   .= model
        , "choices" .= [object
            [ "index"         .= (0 :: Int)
            , "message"       .= object ["role" .= ("assistant" :: Text), "content" .= content]
            , "finish_reason" .= ("stop" :: Text)
            ]]
        , "usage"   .= toJSON usage
        ]

parseOpenAI :: Value -> Maybe (Text, [(Text, Text)], Bool)
parseOpenAI val = parseMaybe parser val
  where
    parser = withObject "OpenAI" $ \v -> do
      model  <- v .:? "model" .!= "deepseek-chat"
      msgs   <- v .:? "messages" .!= ([] :: [Value])
      stream <- v .:? "stream" .!= False
      parsed <- mapM parseMsg msgs
      return (model, parsed, stream)
    parseMsg = withObject "Message" $ \m ->
      (,) <$> m .: "role" <*> m .: "content"

--------------------------------------------------------------------------------
-- 4. Anthropic Compatible API
--------------------------------------------------------------------------------

anthropicMessagesHandler :: LLMAdapter -> Value -> Handler Value
anthropicMessagesHandler adapter body =
  case parseAnthropic body of
    Nothing -> throwError err400 { errBody = "{\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\"}}" }
    Just (model, sys, msgs) -> do
      let hsMsgs = maybe id (\s ms -> LLM.Message LLM.System s : ms) sys
                   $ map (\(r, c) -> LLM.Message (toRole r) c) msgs
      chunks <- liftIO $ llmChat adapter hsMsgs
      let content = T.concat [t | LLM.ChunkDelta t <- chunks]
      let usage = case [u | LLM.ChunkDone u <- chunks] of
            (u:_) -> u
            []    -> LLM.Usage 0 0 0
      return $ object
        [ "id"          .= ("msg-" <> model :: Text)
        , "type"        .= ("message" :: Text)
        , "role"        .= ("assistant" :: Text)
        , "content"     .= [object ["type" .= ("text" :: Text), "text" .= content]]
        , "model"       .= model
        , "stop_reason" .= ("end_turn" :: Text)
        , "usage"       .= object
            [ "input_tokens"  .= LLM.usagePromptTokens usage
            , "output_tokens" .= LLM.usageCompletionTokens usage
            ]
        ]

parseAnthropic :: Value -> Maybe (Text, Maybe Text, [(Text, Text)])
parseAnthropic val = parseMaybe parser val
  where
    parser = withObject "Anthropic" $ \v -> do
      model  <- v .:? "model" .!= "deepseek-chat"
      sys    <- v .:? "system"
      msgs   <- v .:? "messages" .!= ([] :: [Value])
      parsed <- mapM parseMsg msgs
      return (model, sys, parsed)
    parseMsg = withObject "Message" $ \m ->
      (,) <$> m .: "role" <*> m .: "content"

--------------------------------------------------------------------------------
-- 5. Responses API
--------------------------------------------------------------------------------

responsesHandler :: LLMAdapter -> Value -> Handler Value
responsesHandler adapter body =
  case parseResponses body of
    Nothing -> throwError err400 { errBody = "{\"error\":{\"message\":\"input is required\"}}" }
    Just (model, instr, inputMsgs) -> do
      let hsMsgs = maybe id (\i ms -> LLM.Message LLM.System i : ms) instr
                   $ map (\(r, c) -> LLM.Message (toRole r) c) inputMsgs
      chunks <- liftIO $ llmChat adapter hsMsgs
      let content = T.concat [t | LLM.ChunkDelta t <- chunks]
      let usage = case [u | LLM.ChunkDone u <- chunks] of
            (u:_) -> u
            []    -> LLM.Usage 0 0 0
      return $ object
        [ "id"         .= ("resp-" <> model :: Text)
        , "object"     .= ("response" :: Text)
        , "created_at" .= (0 :: Int)
        , "model"      .= model
        , "output"     .= [object
            [ "type"    .= ("message" :: Text)
            , "id"      .= ("msg-" <> model :: Text)
            , "role"    .= ("assistant" :: Text)
            , "status"  .= ("completed" :: Text)
            , "content" .= [object
                [ "type"        .= ("output_text" :: Text)
                , "text"        .= content
                , "annotations" .= ([] :: [Text])
                ]]
            ]]
        , "status"     .= ("completed" :: Text)
        , "usage"      .= toJSON usage
        ]

parseResponses :: Value -> Maybe (Text, Maybe Text, [(Text, Text)])
parseResponses val = parseMaybe parser val
  where
    parser = withObject "Responses" $ \v -> do
      model <- v .:? "model" .!= "deepseek-chat"
      instr <- v .:? "instructions"
      input <- v .: "input"
      msgs  <- case input of
        String s  -> return [("user", s)]
        Array arr -> mapM parseItem (V.toList arr)
        _         -> fail "input must be string or array"
      return (model, instr, msgs)
    parseItem = withObject "InputItem" $ \m ->
      (,) <$> m .:? "role" .!= "user" <*> m .: "content"

--------------------------------------------------------------------------------
-- 7. Streaming endpoints (SSE)
--------------------------------------------------------------------------------

-- | OpenAI streaming: POST /v1/chat/completions/stream
openaiStreamHandler :: LLMAdapter -> Value -> Handler Value
openaiStreamHandler adapter body =
  case parseOpenAI body of
    Nothing -> throwError err400 { errBody = "Invalid request" }
    Just (model, msgs, _stream) -> do
      let hsMsgs = map (\(r, c) -> LLM.Message (toRole r) c) msgs
      -- Collect streaming events into a list
      eventsRef <- liftIO $ newIORef ([] :: [Stream.StreamEvent])
      let onEvent ev = modifyIORef eventsRef (ev :)
      result <- liftIO $ Stream.streamDeepSeek "" model hsMsgs onEvent
      events <- liftIO $ readIORef eventsRef
      let content = T.concat [t | Stream.SEVDelta t <- reverse events]
      let usage = case [(pt, ct, tt) | Stream.SEVUsage pt ct tt <- events] of
            ((pt, ct, tt):_) -> object
              ["prompt_tokens" .= pt, "completion_tokens" .= ct, "total_tokens" .= tt]
            _ -> object ["prompt_tokens" .= (0 :: Int), "completion_tokens" .= (0 :: Int), "total_tokens" .= (0 :: Int)]
      return $ object
        [ "id"      .= ("chatcmpl-stream-" <> model :: Text)
        , "object"  .= ("chat.completion" :: Text)
        , "model"   .= model
        , "choices" .= [object
            [ "index" .= (0 :: Int)
            , "message" .= object ["role" .= ("assistant" :: Text), "content" .= content]
            , "finish_reason" .= ("stop" :: Text)
            ]]
        , "usage"   .= usage
        , "stream_events" .= length events
        ]

-- | Anthropic streaming: POST /v1/messages/stream
anthropicStreamHandler :: LLMAdapter -> Value -> Handler Value
anthropicStreamHandler adapter body =
  case parseAnthropic body of
    Nothing -> throwError err400 { errBody = "Invalid request" }
    Just (model, sys, msgs) -> do
      let hsMsgs = maybe id (\s ms -> LLM.Message LLM.System s : ms) sys
                   $ map (\(r, c) -> LLM.Message (toRole r) c) msgs
      eventsRef <- liftIO $ newIORef ([] :: [Stream.StreamEvent])
      let onEvent ev = modifyIORef eventsRef (ev :)
      result <- liftIO $ Stream.streamAnthropic "" model hsMsgs onEvent
      events <- liftIO $ readIORef eventsRef
      let content = T.concat [t | Stream.SEVDelta t <- reverse events]
      return $ object
        [ "id"          .= ("msg-stream-" <> model :: Text)
        , "type"        .= ("message" :: Text)
        , "role"        .= ("assistant" :: Text)
        , "content"     .= [object ["type" .= ("text" :: Text), "text" .= content]]
        , "model"       .= model
        , "stop_reason" .= ("end_turn" :: Text)
        , "stream_events" .= length events
        ]

-- | Responses streaming: POST /v1/responses/stream
responsesStreamHandler :: LLMAdapter -> Value -> Handler Value
responsesStreamHandler adapter body =
  case parseResponses body of
    Nothing -> throwError err400 { errBody = "Invalid request" }
    Just (model, instr, inputMsgs) -> do
      let hsMsgs = maybe id (\i ms -> LLM.Message LLM.System i : ms) instr
                   $ map (\(r, c) -> LLM.Message (toRole r) c) inputMsgs
      eventsRef <- liftIO $ newIORef ([] :: [Stream.StreamEvent])
      let onEvent ev = modifyIORef eventsRef (ev :)
      result <- liftIO $ Stream.streamDeepSeek "" model hsMsgs onEvent
      events <- liftIO $ readIORef eventsRef
      let content = T.concat [t | Stream.SEVDelta t <- reverse events]
      return $ object
        [ "id"         .= ("resp-stream-" <> model :: Text)
        , "object"     .= ("response" :: Text)
        , "created_at" .= (0 :: Int)
        , "model"      .= model
        , "output"     .= [object
            [ "type"    .= ("message" :: Text)
            , "id"      .= ("msg-stream" :: Text)
            , "role"    .= ("assistant" :: Text)
            , "status"  .= ("completed" :: Text)
            , "content" .= [object
                [ "type"        .= ("output_text" :: Text)
                , "text"        .= content
                , "annotations" .= ([] :: [Text])
                ]]
            ]]
        , "status"     .= ("completed" :: Text)
        , "stream_events" .= length events
        ]

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

toRole :: Text -> LLM.Role
toRole "system"    = LLM.System
toRole "user"      = LLM.User
toRole "assistant" = LLM.Assistant
toRole _           = LLM.User

--------------------------------------------------------------------------------
-- 8. Start server
--------------------------------------------------------------------------------

startServer :: LLMAdapter -> Int -> IO ()
startServer adapter port = do
  sessionsVar <- newTVarIO Map.empty
  putStrLn $ "Starting server on port " ++ show port
  putStrLn "Protocols: OpenAI (/v1/chat/completions), Anthropic (/v1/messages), Responses (/v1/responses)"
  run port (serve (Proxy :: Proxy API) (server adapter sessionsVar))
