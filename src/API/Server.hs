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
  , startStubKernel
  , mkApp
  , mkStubApp
  , mkCPUApp
  , API
  , parseOpenAIRequest
  , OpenAIRequest(..)
  , openaiCompletion
  , openaiToolCompletion
  ) where

import Servant
import Data.Tagged (Tagged(..))
import Network.Wai (Application, responseLBS, responseStream, strictRequestBody)
import Network.Wai.Handler.Warp (run)
import Network.HTTP.Types (ResponseHeaders, status200, status400)
import qualified Data.ByteString.Builder as Builder
import Control.Concurrent (threadDelay)
import Control.Applicative ((<|>))
import Control.Monad.IO.Class (liftIO)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Vector as V
import Data.Aeson
import Data.Maybe (fromMaybe, mapMaybe)
import qualified Data.ByteString.Lazy as BL
import qualified Data.Text.Encoding as TE
import Data.Aeson.Types (Pair, parseMaybe)
import Data.Aeson.Key (fromText)
import qualified Data.Aeson.KeyMap as KM
import Control.Monad (join)
import GHC.Generics
import qualified Data.Map as Map
import Control.Concurrent.STM
import Data.IORef
import Data.Dynamic (toDyn)

-- Core modules
import Core.Agent.StateMachine (AgentCommand (..))
import Core.Session.Types
import Core.Session.Manager
import Core.Agent.Modes
import Core.Provider.Types (ProviderEntry, findProvider)

-- Provider registry handlers (P1: list/protocols, P2: probe, P3: save/…)
import qualified API.Providers as P
import qualified API.ProviderProbe as PP
import qualified API.ProviderRuntime as PR

-- LLM modules
import qualified LLM.Adapter.Types as LLM
import LLM.Adapter.Interface (LLMAdapter(..), createCPUAdapter)
import LLM.Adapter.Types (ChatMessage(..), ChatTurn(..), StreamChunk(..), ToolCall(..), ToolSpec, Usage(..))
import qualified LLM.Stream as Stream
import Infrastructure.CPU.ConstraintVerdict
  ( ConstraintVerdict (..), T6State (..), VerdictStatus (..)
  , verdictOf, verdictOfWithState )

--------------------------------------------------------------------------------
-- 1. Full API type: custom + OpenAI + Anthropic + Responses (stream + non-stream)
--------------------------------------------------------------------------------

type API =
  -- Custom API
       "health" :> Get '[JSON] Value
  :<|> "session" :> "start" :> ReqBody '[JSON] StartReq :> Post '[JSON] Value
  :<|> "agent" :> "step" :> ReqBody '[JSON] StepReq :> Post '[JSON] Value
  -- Provider registry (P1: list + protocols; P2: probe; P3: save/remove/check)
  :<|> "providers" :> Get '[JSON] Value
  :<|> "providers" :> "protocols" :> Get '[JSON] Value
  :<|> "providers" :> "probe" :> ReqBody '[JSON] Value :> Post '[JSON] Value
  :<|> "providers" :> ReqBody '[JSON] Value :> Post '[JSON] Value
  :<|> "providers" :> "remove" :> ReqBody '[JSON] Value :> Post '[JSON] Value
  :<|> "providers" :> "check" :> ReqBody '[JSON] Value :> Post '[JSON] Value
  :<|> "providers" :> "edit" :> ReqBody '[JSON] Value :> Post '[JSON] Value
  :<|> "providers" :> "websearch" :> ReqBody '[JSON] Value :> Post '[JSON] Value
  :<|> "providers" :> "thinking" :> ReqBody '[JSON] Value :> Post '[JSON] Value
  -- OpenAI compatible (non-stream)
  :<|> "v1" :> "models" :> Get '[JSON] Value
  :<|> "v1" :> "chat" :> "completions" :> ReqBody '[JSON] Value :> Post '[JSON] Value
  -- Anthropic compatible (non-stream)
  :<|> "v1" :> "messages" :> ReqBody '[JSON] Value :> Post '[JSON] Value
  -- Responses API (non-stream)
  :<|> "v1" :> "responses" :> ReqBody '[JSON] Value :> Post '[JSON] Value
  -- Streaming endpoints: real SSE, written to the socket as it arrives.
  :<|> "v1" :> "chat" :> "completions" :> "stream" :> Raw
  :<|> "v1" :> "messages" :> "stream" :> Raw
  :<|> "v1" :> "responses" :> "stream" :> Raw

-- Request types
--
-- ⚠️ 契约对齐（2026-09-13 修复）：这两个类型原为 @deriving (Generic, FromJSON)@，
-- 而 aeson 的 Generic 默认用**字段名**（srMode / srSessionId / srMessage）作为 JSON key。
-- 但真实客户端用的是去掉 sr 前缀的名字：
--     packages/app/CLI/Bridge/Scheduler.hs:92   object ["mode" .= ...]
--     packages/app/CLI/Bridge/Scheduler.hs:132  object ["sessionId" .= ..., "message" .= ...]
--     packages/scheduler/test/*.ts              JSON.stringify({ mode / sessionId / message })
-- 于是 POST /session/start 与 POST /agent/step 一直返回 400（此前无测试覆盖这两个端点，
-- 所以未暴露）。现改为手写 FromJSON，**同时接受**两种写法（含 sr 前缀的旧名）以保向后兼容。
data StartReq = StartReq
  { srMode          :: Maybe Text
  , srHostSessionId :: Maybe Text   -- host-supplied id, so the scheduler's
                                    -- session and the kernel's TVar entry are
                                    -- the same key
  }
  deriving (Generic)

data StepReq = StepReq { srSessionId :: Text, srMessage :: Text }
  deriving (Generic)

instance FromJSON StartReq where
  parseJSON = withObject "StartReq" $ \o ->
    StartReq <$> (o .:? "mode" <|> o .:? "srMode")
             <*> (o .:? "sessionId" <|> o .:? "srSessionId")

instance FromJSON StepReq where
  parseJSON = withObject "StepReq" $ \o ->
    StepReq <$> (o .: "sessionId" <|> o .: "srSessionId")
             <*> (o .: "message"   <|> o .: "srMessage")

--------------------------------------------------------------------------------
-- 2. Server implementation
--------------------------------------------------------------------------------

server :: LLMAdapter -> TVar (Map.Map Text Session) -> Server API
server adapter sessions =
       healthHandler
  :<|> startSessionHandler sessions
  :<|> agentStepHandler adapter sessions
  :<|> P.providersHandler
  :<|> P.protocolsHandler
  :<|> PP.probeHandler
  :<|> P.saveProviderHandler
  :<|> P.removeProviderHandler
  :<|> P.checkProviderHandler
  :<|> P.editProviderHandler
  :<|> P.setWebSearchHandler
  :<|> P.setThinkingHandler
  :<|> openaiModelsHandler adapter
  :<|> openaiChatHandler adapter sessions
  :<|> anthropicMessagesHandler adapter
  :<|> responsesHandler adapter
  :<|> openaiStreamApp adapter
  :<|> anthropicStreamApp adapter
  :<|> responsesStreamApp adapter

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
      -- Use the host's session id when supplied; the scheduler keys its own
      -- map by that id, so projections and FSM state land on the same session.
      sid = maybe ("session-" <> T.unpack mode) T.unpack (srHostSessionId req)
  session <- liftIO $ createSession sid
  let key = T.pack (sessionId session)
  liftIO $ atomically $ modifyTVar sessionsVar (Map.insert key session)
  return $ object ["sessionId" .= key, "mode" .= mode]

-- Agent step
agentStepHandler :: LLMAdapter -> TVar (Map.Map Text Session) -> StepReq -> Handler Value
agentStepHandler adapter sessionsVar req = do
  sessions <- liftIO $ readTVarIO sessionsVar
  case Map.lookup (srSessionId req) sessions of
    Nothing -> throwError err404 { errBody = "Session not found" }
    Just session -> do
      let userMsg = LLM.Message LLM.User (srMessage req)
      chunks <- liftIO $ llmChat adapter [userMsg]
      let reply = T.concat [t | LLM.ChunkDelta t <- chunks]
      let usage = case [u | LLM.ChunkDone u <- chunks] of
            (u:_) -> u
            []    -> LLM.Usage 0 0 0
      ----------------------------------------------------------------------
      -- D-3：推理状态上浮为**会话投影**。
      --
      -- 推理内核（T⁶ 几何 / 6×6 因果图 / 五行四步链）的状态此前只活在 CPU 层，内核
      -- 看不到"推理过程"。这里把每步的**末态 T6State** 与**约束判定**写入
      -- session.projections（event-sourcing 式派生状态），使内核可见。
      --
      -- 分层：CPU 层类型在此**装箱**成 Dynamic；Core 只经 setProjection 碰 Dynamic，
      -- 不反向依赖 Infrastructure。
      ----------------------------------------------------------------------
      let (verdict, t6st) = verdictOfWithState (T.unpack reply)
      liftIO $ setProjection session "t6state" (toDyn t6st)
      liftIO $ setProjection session "constraint" (toDyn verdict)
      names <- liftIO $ projectionNames session
      -- D-3：推进内核 FSM（Core.Agent.StateMachine 的 transition 为唯一语义来源）
      stBefore <- liftIO $ getAgentState session
      stAfter  <- liftIO $ advanceAgent session (StartCommand (T.unpack (srSessionId req)))
      return $ object
        [ "reply" .= reply
        , "usage" .= toJSON usage
        -- 让"上浮"可被观测：回显投影名与本步的推理状态摘要（不改变既有字段语义）
        , "session_projections" .= names
        -- 注意：不叫 "t6"，因为 constraintField 里已有同名的判定字段（避免同 key 冲突）
        , "t6_state" .= object
            [ "polar"    .= t6Polar t6st
            , "toroidal" .= t6Toroidal t6st
            , "berry"    .= t6Berry t6st
            ]
        -- 与 /v1/chat/completions 一致：判定随响应返回（复用同一个 constraintField）
        , constraintField reply
        -- D-3：内核 FSM 状态（推理"走到哪一步"）也随之可见
        , "agent_state" .= object
            [ "before" .= show stBefore
            , "after"  .= show stAfter
            ]
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
      , "owned_by"     .= ("trha" :: Text)
      , "description"  .= LLM.modelDescription m
      , "context_size" .= LLM.modelContextSize m
      ]

openaiChatHandler :: LLMAdapter -> TVar (Map.Map Text Session) -> Value -> Handler Value
openaiChatHandler defaultAdapter sessionsVar body = do
  adapter <- dispatchAdapter defaultAdapter body
  case parseOpenAIRequest body of
    Nothing -> throwError err400 { errBody = "Invalid request" }
    Just req
      | null (oaiTools req) -> do
          -- legacy path: role/content messages through the plain chat
          let hsMsgs = [ LLM.Message (toRole r) c
                       | m <- oaiMsgs req
                       , Just (r, c) <- [parseLegacyMessage m] ]
          chunks <- liftIO $ llmChat adapter hsMsgs
          let replyText = T.concat [t | LLM.ChunkDelta t <- chunks]
          liftIO $ touchKernelSession sessionsVar body replyText
          return $ openaiCompletion (oaiModel req) chunks (oaiGenParams req)
      | otherwise -> do
          -- function-calling path: full ChatMessage semantics (incl. tool
          -- results and assistant tool_calls in the history)
          msgs <- case mapM parseChatMsg (oaiMsgs req) of
            Nothing -> throwError err400 { errBody = "Invalid message in tools request" }
            Just ms -> return ms
          specs <- case mapM parseTool (oaiTools req) of
            Nothing -> throwError err400 { errBody = "Invalid tools" }
            Just ts -> return ts
          turn <- liftIO $ llmChatTools adapter msgs specs LLM.defaultGenParams
          -- Tool rounds carry no plain text; still advance the kernel FSM so
          -- the session's step counter stays truthful.
          liftIO $ touchKernelSession sessionsVar body ""
          return $ openaiToolCompletion (oaiModel req) turn (oaiGenParams req)
  where
    parseChatMsg :: Value -> Maybe LLM.ChatMessage
    parseChatMsg v = parseMaybe parseJSON v
    parseTool :: Value -> Maybe LLM.ToolSpec
    parseTool v = parseMaybe parseJSON v

-- | P6: a request may name a provider ("provider": "<name>"); that provider's
-- saved endpoint answers it via its own adapter.  Without a name the kernel's
-- default adapter is used, so every existing caller keeps working.
dispatchAdapter :: LLMAdapter -> Value -> Handler LLMAdapter
dispatchAdapter defaultAdapter body = do
  resolved <- liftIO (resolveAdapterIO defaultAdapter body)
  either (throwError . adapterRefusal) pure resolved

requestedProvider :: Value -> Maybe Text
requestedProvider body = join (parseMaybe (withObject "req" (\o -> o .:? "provider")) body)

-- | Optional kernel-session key on an OpenAI-compatible request.  The desktop
-- scheduler creates the kernel session first and then sends this on every
-- chat/tool round, so projections and FSM state land on the session the host
-- knows about. Absent => the request is served statelessly (plain OpenAI
-- compatibility), and an unknown id is ignored rather than failing the call.
requestedSessionId :: Value -> Maybe Text
requestedSessionId body =
  join (parseMaybe (withObject "req" (\o -> o .:? "sessionId")) body)

-- | Mirror the D-3 projections onto the kernel session named by the request.
touchKernelSession :: TVar (Map.Map Text Session) -> Value -> Text -> IO ()
touchKernelSession sessionsVar body replyText =
  case requestedSessionId body of
    Nothing -> pure ()
    Just sid -> do
      known <- readTVarIO sessionsVar
      case Map.lookup sid known of
        Nothing -> pure ()
        Just session -> do
          let (verdict, t6st) = verdictOfWithState (T.unpack replyText)
          setProjection session "t6state" (toDyn t6st)
          setProjection session "constraint" (toDyn verdict)
          _ <- advanceAgent session (StartCommand (T.unpack sid))
          pure ()

-- | A refusal the UI can act on: HTTP status plus a machine-readable code.
codedRefusal :: Int -> Text -> Text -> ServerError
codedRefusal status code msg = ServerError
  { errHTTPCode = status
  , errReasonPhrase = T.unpack (T.replace "_" " " code)
  , errBody = encode (object [ "code" .= code, "error" .= msg ])
  , errHeaders = [("Content-Type", "application/json")]
  }

-- | Parsed OpenAI chat request: model, raw messages, stream flag,
-- raw tools array (Phase 3 K3).
data OpenAIRequest = OpenAIRequest
  { oaiModel  :: Text
  , oaiMsgs   :: [Value]
  , oaiStream :: Bool
  , oaiTools  :: [Value]
  , oaiGenParams :: Maybe Value   -- {"temperature","topP","maxTokens"} 透传（LLM 设置）
  }

-- | Legacy role/content pair from a plain chat message.
parseLegacyMessage :: Value -> Maybe (Text, Text)
parseLegacyMessage v = parseMaybe (withObject "Message" $ \m ->
  (,) <$> m .: "role" <*> m .: "content") v

-- | Parse the request, preserving the raw @tools@ and message values so
-- the handler can decide between the legacy and the tool-calling path.
parseOpenAIRequest :: Value -> Maybe OpenAIRequest
parseOpenAIRequest val = parseMaybe parser val
  where
    parser = withObject "OpenAI" $ \v -> OpenAIRequest
      <$> (v .:? "model" .!= "deepseek-chat")
      <*> (v .:? "messages" .!= ([] :: [Value]))
      <*> (v .:? "stream" .!= False)
      <*> (v .:? "tools" .!= ([] :: [Value]))
      <*> (v .:? "genParams")

-- | Legacy completion response (no tools).
-- | C5(D-1)：约束的**采纳判定**作为一个可复用的响应字段。
--
-- 作用点在**响应侧** —— 外部模型是黑盒（不能改其权重/采样），约束不可能作用于它的
-- 内部计算，只能作用于"哪些输出被采纳"。这里把候选输出投影到约束输入空间，过一遍
-- T⁶ / 6×6 因果图 / 五行四步链。判定**总是**产出（用户裁定①：标注而非拒绝、不降级）；
-- 草稿（本地）与外部输出共用这一条路径（裁定③：同一机制的两面）。
constraintField :: Text -> Pair
constraintField content =
  "trha_constraint"
    .= object
      [ "status" .= (case cvStatus v of
                       VerdictPass -> "pass" :: Text
                       VerdictWarn -> "warn")
      , "t6"     .= cvT6 v
      , "reach"  .= cvReach v
      , "edges"  .= cvEdges v
      , "reason" .= T.pack (cvReason v)
      ]
  where
    v = verdictOf (T.unpack content)

openaiCompletion :: Text -> [LLM.StreamChunk] -> Maybe Value -> Value
openaiCompletion model chunks genParams = object
  ( [ "id"      .= ("chatcmpl-" <> model :: Text)
    , "object"  .= ("chat.completion" :: Text)
    , "model"   .= model
    , "choices" .= [object
        [ "index"         .= (0 :: Int)
        , "message"       .= object ["role" .= ("assistant" :: Text), "content" .= content]
        , "finish_reason" .= ("stop" :: Text)
        ]]
    , "usage"   .= toJSON usage
  , constraintField content
  ] ++ genParamsEcho genParams )
  where
    content = T.concat [t | LLM.ChunkDelta t <- chunks]
    usage = case [u | LLM.ChunkDone u <- chunks] of
      (u : _) -> u
      []      -> LLM.Usage 0 0 0

-- | Tool-calling completion response (Phase 3 K3).
openaiToolCompletion :: Text -> LLM.ChatTurn -> Maybe Value -> Value
openaiToolCompletion model turn genParams = object
  ( [ "id"      .= ("chatcmpl-" <> model :: Text)
    , "object"  .= ("chat.completion" :: Text)
    , "model"   .= model
    , "choices" .= [object
      [ "index"         .= (0 :: Int)
      , "message"       .= object
          ( [ "role" .= ("assistant" :: Text), "content" .= LLM.ctContent turn ]
              ++ [ "tool_calls" .= LLM.ctToolCalls turn | not (null (LLM.ctToolCalls turn)) ] )
      , "finish_reason" .= (if null (LLM.ctToolCalls turn) then ("stop" :: Text) else "tool_calls")
      ]]
  , "usage" .= maybe (toJSON (LLM.Usage 0 0 0)) toJSON (LLM.ctUsage turn)
  , constraintField (LLM.ctContent turn)
  ] ++ genParamsEcho genParams )

-- | 回显内核收到的生成参数（LLM 设置透传的诚实证据；无参数时为空）。
genParamsEcho :: Maybe Value -> [Pair]
genParamsEcho Nothing = []
genParamsEcho (Just v) = [ "gen_params_applied" .= v ]

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
      -- C5(D-1) 裁定③：草稿（本地）输出与外部输出走**同一条**判定入口。
      -- C5(D-1)：约束的**作用点 = 响应侧的采纳判定**。
      -- 外部模型是黑盒（不能改其权重/采样），约束不可能作用于其内部计算，只能作用于
      -- "哪些输出被采纳"。这里把候选输出投影到约束输入空间，过一遍 T⁶ / 6×6 因果图 /
      -- 五行四步链；判定**总是**随响应返回（用户裁定①：标注而非拒绝，不降级）。
      let verdict = verdictOf (T.unpack content)
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
        , constraintField content
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
      -- C5(D-1) 裁定③：草稿（本地）输出与外部输出走**同一条**判定入口。
      -- C5(D-1)：约束的**作用点 = 响应侧的采纳判定**。
      -- 外部模型是黑盒（不能改其权重/采样），约束不可能作用于其内部计算，只能作用于
      -- "哪些输出被采纳"。这里把候选输出投影到约束输入空间，过一遍 T⁶ / 6×6 因果图 /
      -- 五行四步链；判定**总是**随响应返回（用户裁定①：标注而非拒绝，不降级）。
      let verdict = verdictOf (T.unpack content)
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

-- | Where a streaming request should go: the provider it names, if any.
streamingTarget :: Value -> IO (Maybe (ProviderEntry, Text))
streamingTarget body = case requestedProvider body of
  Nothing   -> pure Nothing
  Just name -> do
    store <- P.loadProviderStore
    case findProvider name store of
      Nothing    -> pure Nothing
      Just entry -> do
        mkey <- P.resolveKey name =<< P.loadKeys
        pure (Just (entry, maybe "" id mkey))

-- | Why a request's provider could not be used.
data AdapterError
  = UnknownProvider Text       -- ^ nothing is saved under that name
  | UnavailableProvider Text   -- ^ saved, but its wire could not be built
  deriving (Show, Eq)

-- | Which adapter answers a request: the named provider's, or the default.
-- One implementation, shared by the blocking (Handler) and the streaming
-- (Application) path -- the two can never disagree about provider lookup.
resolveAdapterIO :: LLMAdapter -> Value -> IO (Either AdapterError LLMAdapter)
resolveAdapterIO defaultAdapter body =
  case requestedProvider body of
    Nothing   -> pure (Right defaultAdapter)
    Just name -> do
      store <- P.loadProviderStore
      case findProvider name store of
        Nothing    -> pure (Left (UnknownProvider name))
        Just entry -> do
          mkey <- P.resolveKey name =<< P.loadKeys
          built <- PR.adapterFor entry (maybe "" id mkey)
          pure (either (Left . UnavailableProvider) Right built)

-- | The resolution as a coded HTTP refusal (Handler path).
adapterRefusal :: AdapterError -> ServerError
adapterRefusal (UnknownProvider name) =
  codedRefusal 404 "provider.unknown" ("no provider named " <> name)
adapterRefusal (UnavailableProvider why) =
  codedRefusal 502 "provider.adapter_unavailable" why

-- | The same failure as plain text: the streaming path reports in-band, in an
-- SSE error frame, so it needs no HTTP status of its own.
adapterRefusalText :: AdapterError -> Text
adapterRefusalText (UnknownProvider name)    = "no provider named " <> name
adapterRefusalText (UnavailableProvider why) = why

-- | A field of a JSON object.
lookupField :: Text -> Object -> Maybe Value
lookupField k o = KM.lookup (fromText k) o

-- | An array field of a JSON body ([] when absent or not an array).
rawArray :: Text -> Value -> [Value]
rawArray k v = case v of
  Object o -> case lookupField k o of
    Just (Array a) -> V.toList a
    _              -> []
  _ -> []

-- | A value back as compact JSON text (arguments are strings on the wire).
jsonTextOf :: Value -> Text
jsonTextOf = TE.decodeUtf8 . BL.toStrict . encode

-- | One Anthropic message as the kernel's chat type — text, @tool_use@ and
-- @tool_result@ blocks all survive, so a tool loop can close.
anthropicChatMsg :: Value -> Maybe ChatMessage
anthropicChatMsg v = case v of
  Object o -> do
    role <- case lookupField "role" o of
      Just (String r) -> Just r
      _               -> Nothing
    let blocks = case lookupField "content" o of
          Just (String t) -> [ object [ "type" .= ("text" :: Text), "text" .= t ] ]
          Just (Array a)  -> V.toList a
          _               -> []
        texts   = [ t | Object b <- blocks, lookupField "type" b == Just (String "text")
                      , Just (String t) <- [lookupField "text" b] ]
        uses    = [ LLM.ToolCall (asTextOf (lookupField "id" b)) (asTextOf (lookupField "name" b))
                             (jsonTextOf (fromMaybe Null (lookupField "input" b)))
                  | Object b <- blocks, lookupField "type" b == Just (String "tool_use") ]
        results = [ (asTextOf (lookupField "tool_use_id" b), asTextOf (lookupField "content" b))
                  | Object b <- blocks, lookupField "type" b == Just (String "tool_result") ]
    Just $ case (role, results) of
      ("user", (cid, out):_) -> ChatTool cid (if T.null (T.strip out) then "(no output)" else out)
      ("assistant", _)       -> ChatAssistant (T.concat texts) uses
      ("user", [])           -> ChatUser (T.concat texts)
      _                      -> ChatSystem (T.concat texts)
  _ -> Nothing

-- | One Responses input item as the kernel's chat type (@function_call@ and
-- @function_call_output@ included).
responsesChatMsg :: Value -> Maybe ChatMessage
responsesChatMsg v = case v of
  Object o -> case lookupField "type" o of
    Just (String "function_call") ->
      Just (ChatAssistant "" [ LLM.ToolCall (asTextOf (lookupField "call_id" o))
                                        (asTextOf (lookupField "name" o))
                                        (asTextOf (lookupField "arguments" o)) ])
    Just (String "function_call_output") ->
      Just (ChatTool (asTextOf (lookupField "call_id" o)) (asTextOf (lookupField "output" o)))
    _ -> case lookupField "role" o of
      Just (String role) ->
        let content = case lookupField "content" o of
              Just (String t) -> t
              Just (Array a)  -> T.concat
                [ asTextOf (lookupField "text" b) | Object b <- V.toList a ]
              _               -> ""
        in Just $ if role == "system" then ChatSystem content else ChatUser content
      _ -> Nothing
  _ -> Nothing

-- | A JSON string field as plain text.
asTextOf :: Maybe Value -> Text
asTextOf (Just (String t)) = t
asTextOf _                 = ""

-- | Run the named provider's streaming call, re-expressed in the kernel's own
-- event type so the endpoints below keep their existing shape.
providerEvents :: (ProviderEntry, Text) -> [ChatMessage] -> [ToolSpec] -> (Stream.StreamEvent -> IO ()) -> IO ()
providerEvents (entry, key) msgs specs onEvent = do
  call <- PR.providerStream entry key
  _ <- call msgs specs $ \chunk -> case chunk of
    ChunkDelta t    -> onEvent (Stream.SEVDelta t)
    ChunkToolCall n a -> onEvent (Stream.SEVToolCall n a)
    ChunkDone u     -> onEvent (Stream.SEVUsage (usagePromptTokens u) (usageCompletionTokens u) (usageTotalTokens u))
    ChunkError e    -> onEvent (Stream.SEVError e)
  pure ()

-- | Role/content pairs as the kernel's function-calling message type.
toChatMessages :: [(Text, Text)] -> [ChatMessage]
toChatMessages = map $ \(r, c) -> case r of
  "system"    -> ChatSystem c
  "assistant" -> ChatAssistant c []
  _           -> ChatUser c

-- | POST /v1/chat/completions/stream — real SSE: every increment is written
-- to the socket the moment the provider produces it.
openaiStreamApp :: LLMAdapter -> Tagged Handler Application
openaiStreamApp adapter = Tagged $ \req respond -> do
  raw <- strictRequestBody req
  case decode raw of
    Nothing -> respond (responseLBS status400 [] "Invalid request")
    Just v -> case parseOpenAIRequest v of
      Nothing -> respond (responseLBS status400 [] "Invalid request")
      Just oai -> do
        effAdapter <- resolveAdapterIO adapter v
        -- Full-fidelity messages straight from the wire: tool results and the
        -- assistant's own tool_calls must survive, or the tool loop can never
        -- close (a `tool` turn flattened to user text looks like a new demand).
        let msgs  = [ m | Just m <- map (parseMaybe parseJSON) (oaiMsgs oai) ]
            specs = [ sp | Just sp <- map (parseMaybe parseJSON) (oaiTools oai) ]
        respond $ responseStream status200 sseHeaders $ \write flush -> do
          case effAdapter of
            Left why -> emitOpenAI write (ChunkError (adapterRefusalText why)) >> flush
            Right a  -> do
              _ <- llmChatToolsStream a msgs specs (\chunk -> emitOpenAI write chunk >> flush)
              pure ()
          write (Builder.string8 "data: [DONE]\n\n")
          flush

-- | OpenAI streaming: POST /v1/chat/completions/stream
openaiStreamHandler :: LLMAdapter -> Value -> Handler Value
openaiStreamHandler adapter body =
  case parseOpenAIRequest body of
    Nothing -> throwError err400 { errBody = "Invalid request" }
    Just req -> do
      let model = oaiModel req
          hsMsgs = [ LLM.Message (toRole r) c
                   | m <- oaiMsgs req
                   , Just (r, c) <- [parseLegacyMessage m] ]
          specs = [ sp | Just sp <- map (parseMaybe parseJSON) (oaiTools req) ]
      -- Collect streaming events into a list
      eventsRef <- liftIO $ newIORef ([] :: [Stream.StreamEvent])
      let onEvent ev = modifyIORef eventsRef (ev :)
      target <- liftIO (streamingTarget body)
      result <- liftIO $ case target of
        Just t  -> providerEvents t
                     (toChatMessages [ (r, c) | m <- oaiMsgs req, Just (r, c) <- [parseLegacyMessage m] ])
                     specs
                     onEvent >> pure (Right ())
        Nothing -> Stream.streamDeepSeek "" model hsMsgs onEvent
      events <- liftIO $ readIORef eventsRef
      let content = T.concat [t | Stream.SEVDelta t <- reverse events]
      -- C5(D-1)：约束的**作用点 = 响应侧的采纳判定**。
      -- 外部模型是黑盒（不能改其权重/采样），约束不可能作用于其内部计算，只能作用于
      -- "哪些输出被采纳"。这里把候选输出投影到约束输入空间，过一遍 T⁶ / 6×6 因果图 /
      -- 五行四步链；判定**总是**随响应返回（用户裁定①：标注而非拒绝，不降级）。
      let verdict = verdictOf (T.unpack content)
      let toolCalls = streamedToolCalls (reverse events)
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
            , "message" .= object (
                [ "role" .= ("assistant" :: Text), "content" .= content ]
                ++ [ "tool_calls" .= [ object
                        [ "id" .= ("call_" <> T.pack (show i) :: Text)
                        , "type" .= ("function" :: Text)
                        , "function" .= object ["name" .= n, "arguments" .= a]
                        ] | (i, (n, a)) <- zip [(0 :: Int) ..] toolCalls ]
                   | not (null toolCalls) ])
            , "finish_reason" .= (if null toolCalls then "stop" else "tool_calls" :: Text)
            ]]
        , "usage"   .= usage
        , "stream_events" .= length events
        -- 约束判定：status 为 pass / warn；**总是**存在（warn 时仍返回内容，仅标注）。
        , "trha_constraint" .= object
            [ "status" .= (case cvStatus verdict of
                             VerdictPass -> "pass" :: Text
                             VerdictWarn -> "warn")
            , "t6"     .= cvT6 verdict
            , "reach"  .= cvReach verdict
            , "edges"  .= cvEdges verdict
            , "reason" .= T.pack (cvReason verdict)
            ]
        ]

-- | POST /v1/messages/stream — the Messages API's named-event SSE.
anthropicStreamApp :: LLMAdapter -> Tagged Handler Application
anthropicStreamApp adapter = Tagged $ \req respond -> do
  raw <- strictRequestBody req
  case decode raw of
    Nothing -> respond (responseLBS status400 [] "Invalid request")
    Just v -> case parseAnthropic v of
      Nothing -> respond (responseLBS status400 [] "Invalid request")
      Just (model, sys, msgs) -> do
        effAdapter <- resolveAdapterIO adapter v
        -- Faithful turns: a tool_result block must not be flattened to user
        -- text, or the tool loop can never close.
        let convo = maybe id (\x m -> ChatSystem x : m) sys
                      (mapMaybe anthropicChatMsg (rawArray "messages" v))
        respond $ responseStream status200 sseHeaders $ \write flush -> do
          case effAdapter of
            Left why -> emitAnthropic write (ChunkError (adapterRefusalText why)) >> flush
            Right a  -> do
              _ <- llmChatToolsStream a convo [] (\chunk -> emitAnthropic write chunk >> flush)
              pure ()
          emitAnthropic write (ChunkDone (Usage 0 0 0)) >> flush

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
      target <- liftIO (streamingTarget body)
      result <- liftIO $ case target of
        Just t  -> providerEvents t
                     (toChatMessages (maybe [] (\x -> [("system", x)]) sys ++ msgs))
                     []
                     onEvent >> pure (Right ())
        Nothing -> Stream.streamAnthropic "" model hsMsgs onEvent
      events <- liftIO $ readIORef eventsRef
      let content = T.concat [t | Stream.SEVDelta t <- reverse events]
      -- C5(D-1)：约束的**作用点 = 响应侧的采纳判定**。
      -- 外部模型是黑盒（不能改其权重/采样），约束不可能作用于其内部计算，只能作用于
      -- "哪些输出被采纳"。这里把候选输出投影到约束输入空间，过一遍 T⁶ / 6×6 因果图 /
      -- 五行四步链；判定**总是**随响应返回（用户裁定①：标注而非拒绝，不降级）。
      let verdict = verdictOf (T.unpack content)
      let toolCalls = streamedToolCalls (reverse events)
      return $ object
        [ "id"          .= ("msg-stream-" <> model :: Text)
        , "type"        .= ("message" :: Text)
        , "role"        .= ("assistant" :: Text)
        , "content"     .= (
            [ object ["type" .= ("text" :: Text), "text" .= content] | not (T.null content) ]
            ++ [ object [ "type" .= ("tool_use" :: Text), "name" .= n, "input" .= rawJson a ]
               | (n, a) <- toolCalls ])
        , "model"       .= model
        , "stop_reason" .= (if null toolCalls then "end_turn" else "tool_use" :: Text)
        , "stream_events" .= length events
        -- 约束判定：status 为 pass / warn；**总是**存在（warn 时仍返回内容，仅标注）。
        , "trha_constraint" .= object
            [ "status" .= (case cvStatus verdict of
                             VerdictPass -> "pass" :: Text
                             VerdictWarn -> "warn")
            , "t6"     .= cvT6 verdict
            , "reach"  .= cvReach verdict
            , "edges"  .= cvEdges verdict
            , "reason" .= T.pack (cvReason verdict)
            ]
        ]

-- | POST /v1/responses/stream — the Responses API's typed-event SSE.
responsesStreamApp :: LLMAdapter -> Tagged Handler Application
responsesStreamApp adapter = Tagged $ \req respond -> do
  raw <- strictRequestBody req
  case decode raw of
    Nothing -> respond (responseLBS status400 [] "Invalid request")
    Just v -> case parseResponses v of
      Nothing -> respond (responseLBS status400 [] "Invalid request")
      Just (model, instr, inputMsgs) -> do
        effAdapter <- resolveAdapterIO adapter v
        -- Faithful items: function_call_output must survive as a tool turn.
        let convo = maybe id (\x m -> ChatSystem x : m) instr
                      (mapMaybe responsesChatMsg (rawArray "input" v))
        respond $ responseStream status200 sseHeaders $ \write flush -> do
          case effAdapter of
            Left why -> emitResponses write (ChunkError (adapterRefusalText why)) >> flush
            Right a  -> do
              _ <- llmChatToolsStream a convo [] (\chunk -> emitResponses write chunk >> flush)
              pure ()
          emitResponses write (ChunkDone (Usage 0 0 0)) >> flush


-- Helpers
-- ----- | Responses streaming: POST /v1/responses/stream
responsesStreamHandler :: LLMAdapter -> Value -> Handler Value
responsesStreamHandler adapter body =
  case parseResponses body of
    Nothing -> throwError err400 { errBody = "Invalid request" }
    Just (model, instr, inputMsgs) -> do
      let hsMsgs = maybe id (\i ms -> LLM.Message LLM.System i : ms) instr
                   $ map (\(r, c) -> LLM.Message (toRole r) c) inputMsgs
      eventsRef <- liftIO $ newIORef ([] :: [Stream.StreamEvent])
      let onEvent ev = modifyIORef eventsRef (ev :)
      target <- liftIO (streamingTarget body)
      result <- liftIO $ case target of
        Just t  -> providerEvents t
                     (toChatMessages (maybe [] (\x -> [("system", x)]) instr ++ inputMsgs))
                     []
                     onEvent >> pure (Right ())
        Nothing -> Stream.streamDeepSeek "" model hsMsgs onEvent
      events <- liftIO $ readIORef eventsRef
      let content = T.concat [t | Stream.SEVDelta t <- reverse events]
      -- C5(D-1)：约束的**作用点 = 响应侧的采纳判定**。
      -- 外部模型是黑盒（不能改其权重/采样），约束不可能作用于其内部计算，只能作用于
      -- "哪些输出被采纳"。这里把候选输出投影到约束输入空间，过一遍 T⁶ / 6×6 因果图 /
      -- 五行四步链；判定**总是**随响应返回（用户裁定①：标注而非拒绝，不降级）。
      let verdict = verdictOf (T.unpack content)
      let toolCalls = streamedToolCalls (reverse events)
      return $ object
        [ "id"         .= ("resp-stream-" <> model :: Text)
        , "object"     .= ("response" :: Text)
        , "created_at" .= (0 :: Int)
        , "model"      .= model
        , "output"     .= (
            [ object
                [ "type"    .= ("message" :: Text)
                , "id"      .= ("msg-stream" :: Text)
                , "role"    .= ("assistant" :: Text)
                , "status"  .= ("completed" :: Text)
                , "content" .= [object
                    [ "type"        .= ("output_text" :: Text)
                    , "text"        .= content
                    , "annotations" .= ([] :: [Text])
                    ]]
                ] ]
            ++ [ object
                   [ "type"      .= ("function_call" :: Text)
                   , "id"        .= ("fc-stream" <> T.pack (show i) :: Text)
                   , "call_id"   .= ("call_" <> T.pack (show i) :: Text)
                   , "name"      .= n
                   , "arguments" .= a
                   ] | (i, (n, a)) <- zip [(0 :: Int) ..] toolCalls ])
        , "status"     .= ("completed" :: Text)
        , "stream_events" .= length events
        -- 约束判定：status 为 pass / warn；**总是**存在（warn 时仍返回内容，仅标注）。
        , "trha_constraint" .= object
            [ "status" .= (case cvStatus verdict of
                             VerdictPass -> "pass" :: Text
                             VerdictWarn -> "warn")
            , "t6"     .= cvT6 verdict
            , "reach"  .= cvReach verdict
            , "edges"  .= cvEdges verdict
            , "reason" .= T.pack (cvReason verdict)
            ]
        ]

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

-- | Headers every SSE response carries; @X-Accel-Buffering: no@ keeps proxies
-- from holding the frames back.
sseHeaders :: ResponseHeaders
sseHeaders =
  [ ("Content-Type", "text/event-stream")
  , ("Cache-Control", "no-cache")
  , ("Connection", "keep-alive")
  , ("X-Accel-Buffering", "no")
  ]

-- | One SSE frame: an optional @event:@ line, then the JSON payload.
sse :: (Builder.Builder -> IO ()) -> Maybe Text -> [Pair] -> IO ()
sse write eventName pairs = write $ mconcat $
  [ Builder.string8 "event: " <> Builder.string8 (T.unpack e) <> Builder.string8 "\n"
  | e <- maybe [] pure eventName ]
  ++ [ Builder.string8 "data: "
     , Builder.byteString (BL.toStrict (encode (object pairs)))
     , Builder.string8 "\n\n" ]

-- | The kernel's own event type back as an adapter chunk.
fromKernelEvent :: Stream.StreamEvent -> StreamChunk
fromKernelEvent (Stream.SEVDelta t)      = ChunkDelta t
fromKernelEvent (Stream.SEVToolCall n a) = ChunkToolCall n a
fromKernelEvent (Stream.SEVUsage p c t)  = ChunkDone (Usage p c t)
fromKernelEvent Stream.SEVDone           = ChunkDone (Usage 0 0 0)
fromKernelEvent (Stream.SEVError e)      = ChunkError e

-- | OpenAI-compatible frames (@choices[0].delta@).
emitOpenAI :: (Builder.Builder -> IO ()) -> StreamChunk -> IO ()
emitOpenAI write chunk = case chunk of
  ChunkDelta t -> sse write Nothing
    [ "choices" .= [object ["index" .= (0 :: Int), "delta" .= object ["content" .= t]]] ]
  ChunkToolCall n a -> sse write Nothing
    [ "choices" .= [object [ "index" .= (0 :: Int)
                           , "delta" .= object [ "tool_calls" .= [ object
                               [ "index" .= (0 :: Int)
                               , "function" .= object ["name" .= n, "arguments" .= a] ] ] ] ]] ]
  ChunkDone _ -> sse write Nothing
    [ "choices" .= [object [ "index" .= (0 :: Int), "delta" .= object []
                           , "finish_reason" .= ("stop" :: Text) ]] ]
  ChunkError e -> sse write Nothing [ "error" .= object ["message" .= e] ]

-- | Anthropic frames (@content_block_delta@ / @content_block_start@).
emitAnthropic :: (Builder.Builder -> IO ()) -> StreamChunk -> IO ()
emitAnthropic write chunk = case chunk of
  ChunkDelta t -> sse write (Just "content_block_delta")
    [ "type" .= ("content_block_delta" :: Text)
    , "index" .= (0 :: Int)
    , "delta" .= object [ "type" .= ("text_delta" :: Text), "text" .= t ] ]
  ChunkToolCall n a -> sse write (Just "content_block_start")
    [ "type" .= ("content_block_start" :: Text)
    , "index" .= (1 :: Int)
    , "content_block" .= object
        [ "type" .= ("tool_use" :: Text)
        , "id"   .= ("toolu_stream" :: Text)
        , "name" .= n
        , "input" .= rawJson a ] ]
  ChunkDone _ -> sse write (Just "message_stop") [ "type" .= ("message_stop" :: Text) ]
  ChunkError e -> sse write (Just "error")
    [ "type" .= ("error" :: Text), "error" .= object ["message" .= e] ]

-- | Responses frames (@response.output_text.delta@ / @response.output_item.added@).
emitResponses :: (Builder.Builder -> IO ()) -> StreamChunk -> IO ()
emitResponses write chunk = case chunk of
  ChunkDelta t -> sse write (Just "response.output_text.delta")
    [ "type" .= ("response.output_text.delta" :: Text), "delta" .= t ]
  ChunkToolCall n a -> sse write (Just "response.output_item.added")
    [ "type" .= ("response.output_item.added" :: Text)
    , "item" .= object
        [ "type" .= ("function_call" :: Text), "name" .= n, "arguments" .= a ] ]
  ChunkDone _ -> sse write (Just "response.completed")
    [ "type" .= ("response.completed" :: Text) ]
  ChunkError e -> sse write (Just "error")
    [ "type" .= ("error" :: Text), "message" .= e ]

-- | Tool calls carried by the events of one streaming request.

streamedToolCalls :: [Stream.StreamEvent] -> [(Text, Text)]
streamedToolCalls events = [ (n, a) | Stream.SEVToolCall n a <- events ]

-- | An arguments string embedded back into JSON (kept as a string if it does
-- not parse, so the caller still sees what the model said).
rawJson :: Text -> Value
rawJson t = fromMaybe (String t) (decode (BL.fromStrict (TE.encodeUtf8 t)))

toRole :: Text -> LLM.Role
toRole "system"    = LLM.System
toRole "user"      = LLM.User
toRole "assistant" = LLM.Assistant
toRole _           = LLM.User

--------------------------------------------------------------------------------
-- 8. Start server
--------------------------------------------------------------------------------

-- | The server as a WAI 'Application', with the backend injected.
--
-- Split out of 'startServer' so tests can drive the **real** API through
-- @testWithApplication@ without binding a fixed port.  Everything that decides
-- which backend answers HTTP flows through this one argument: swap the
-- 'LLMAdapter' and every endpoint follows.
mkApp :: LLMAdapter -> IO Application
mkApp adapter = do
  sessionsVar <- newTVarIO Map.empty
  pure (serve (Proxy :: Proxy API) (server adapter sessionsVar))

startServer :: LLMAdapter -> Int -> IO ()
startServer adapter port = do
  app <- mkApp adapter
  putStrLn $ "Starting server on port " ++ show port
  putStrLn "Protocols: OpenAI (/v1/chat/completions), Anthropic (/v1/messages), Responses (/v1/responses)"
  run port app

-- | The stub-backed app (K6): deterministic two-round tool loop, no provider
-- key and no model file.  Same wiring the production @startStubKernel@ uses.
mkStubApp :: IO Application
mkStubApp = stubAdapter >>= mkApp

-- | The **local CPU engine**-backed app: the real inference stack answers every
-- endpoint, SSE included.
--
-- ⚠️ Why the adapter is built *here* instead of being passed in: this package
-- compiles its own copy of @LLM.Adapter.Interface@ (listed in @other-modules@),
-- so @trha-api@'s 'LLMAdapter' and @trha-llm@'s 'LLMAdapter' are **different
-- types** despite sharing a module name and source file.  An adapter obtained
-- from @trha-llm@ — @createCPUAdapter@ as seen from outside this package — cannot
-- be handed to 'mkApp'.  Building it inside the package keeps the types aligned.
-- Creating the engine here is also exactly where the wiring gap lives: nothing
-- outside this module can currently inject a CPU backend.
mkCPUApp :: FilePath -> IO Application
mkCPUApp modelPath = createCPUAdapter modelPath >>= mkApp . snd

--------------------------------------------------------------------------------
-- Stub kernel (K6): two-round tool loop without a real provider.
--------------------------------------------------------------------------------

-- | A kernel that answers the first tool-bearing request with a read_file
-- tool call and the second (which carries the tool result) with the result
-- echoed back -- enough to exercise the orchestration tool loop end to end.
stubAdapter :: IO LLMAdapter
stubAdapter = return $ LLMAdapter
  { llmChat = \msgs -> do
      let lastText = if null msgs then "" else LLM.messageContent (last msgs)
      return [ LLM.ChunkDelta ("[stub] " <> lastText), LLM.ChunkDone (LLM.Usage 1 1 2) ]
  , llmChatTools = \msgs specs _gp -> stubTools msgs specs
  , llmEmbed = \_ -> return []
  , llmModels = return [ LLM.ModelInfo "stub" "Stub Kernel" 4096 ]
  , llmChatToolsStream = stubStream
  }

-- | The stub streams for real: it announces its answer in two pieces with a
-- short gap, so "the first byte arrived well before the end" is observable.
stubStream :: [LLM.ChatMessage] -> [LLM.ToolSpec] -> (LLM.StreamChunk -> IO ()) -> IO LLM.ChatTurn
stubStream msgs specs onEvent = do
  turn <- stubTools msgs specs
  mapM_ (\tc -> onEvent (LLM.ChunkToolCall (LLM.tcName tc) (LLM.tcArguments tc)))
        (LLM.ctToolCalls turn)
  case LLM.ctError turn of
    Just e  -> onEvent (LLM.ChunkError e)
    Nothing -> do
      let txt = LLM.ctContent turn
          (headBit, restBits) = T.splitAt 1 txt
      onEvent (LLM.ChunkDelta headBit)
      threadDelay 30000          -- 30ms: a real gap no buffering can hide
      onEvent (LLM.ChunkDelta restBits)
      onEvent (LLM.ChunkDone (maybe (LLM.Usage 0 0 0) id (LLM.ctUsage turn)))
  pure turn

-- | The stub's tool-calling answer, shared by both call paths.
stubTools :: [LLM.ChatMessage] -> [LLM.ToolSpec] -> IO LLM.ChatTurn
stubTools msgs _specs = do
  let toolResults = [ r | LLM.ChatTool _ r <- msgs ]
  if null toolResults
    then return $ LLM.ChatTurn ""
             [ LLM.ToolCall "call-stub" "read_file" "{\"path\":\"/etc/hostname\"}" ]
             (Just (LLM.Usage 1 1 2)) Nothing
    else return $ LLM.ChatTurn ("[stub] tool said: " <> last toolResults)
             [] (Just (LLM.Usage 1 1 2)) Nothing

-- | Start the stub kernel on the given port.
startStubKernel :: Int -> IO ()
startStubKernel port = do
  adapter <- stubAdapter
  startServer adapter port
