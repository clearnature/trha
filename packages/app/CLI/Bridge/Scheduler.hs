{-# LANGUAGE OverloadedStrings #-}

-- | Bridge from the CLI/TUI shell to the TypeScript orchestration layer
-- (packages/scheduler).  Wire protocol (Phase 2 S0 alignment):
--
--   POST   /api/session/start       {mode}          -> {sessionId, mode}
--   GET    /api/sessions                            -> [ {id, mode, ...} ]
--   GET    /api/session/:id                         -> {id, mode, messages, ...}
--   DELETE /api/session/:id                         -> 200
--   POST   /api/agent/step          {sessionId,message} -> {reply, messages, mode}
--   POST   /api/session/:id/interrupt               -> {aborted}
--   GET    /api/session/:id/messages                -> {messages: [{role, content}]}
--   GET    /api/models                              -> [ {name, description, contextSize} ]
--   GET    /health                                  -> {status, ...}
--
-- Functions that have no counterpart in the orchestration API return an
-- explicit 'UnknownCLIError' instead of pretending to work.
module Bridge.Scheduler
  ( -- * Scheduler Bridge
    SchedulerBridge(..)
  , createSchedulerBridge

    -- * Session Operations
  , createSession
  , listSessions
  , getSession
  , deleteSession

    -- * Message Operations
  , sendMessage
  , sendMessageWithUsage
  , sendMessageWithTarget
  , getMessages
  , allowAlways
  , interruptSession
  , fetchTeamTasks
  , listProviders

    -- * Session Events (SSE, Phase 2 S2)
  , subscribeSessionEvents
  , subscribeSessionEventsWith
  , subscribeSessionEventsWithTerminal

    -- * Plan / Approval (Phase 2 S1)
  , planStep
  , approvePlan
  , denyPlan

    -- * Multi-step plans (kernel-owned)
  , submitPlan
  , fetchPlan
  , decideStep
  , decidePlan
  , reportStep

    -- * Agent Operations
  , getAgentState
  , updateAgentState

    -- * Model Operations
  , listModels
  , getModel

    -- * Plugins (Phase 3)
  , listPlugins

    -- * Health Check
  , healthCheck
  ) where

import Core.Types
import Core.HTTP
import Core.SSE (SseDecoder, SsePayload(..), classifyPayload, feed, newDecoder)
import Data.Aeson
import qualified Data.Aeson.KeyMap as KM
import Data.Aeson.Types (parseMaybe, (.:))
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Control.Concurrent (forkIO, killThread, newEmptyMVar, putMVar, takeMVar)
import Control.Monad (void, when)
import Data.Maybe (fromMaybe)
import System.Timeout (timeout)
import Control.Exception (catch)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Network.HTTP.Client
    ( BodyReader, managerResponseTimeout, managerSetProxy, newManager, noProxy
    , parseRequest, requestHeaders, responseBody, responseTimeoutNone, withResponse, brRead
    )
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Network.HTTP.Types (HeaderName)

-- | Scheduler bridge
data SchedulerBridge = SchedulerBridge
  { bridgeConfig :: CLIConfig
  , bridgeHTTP   :: HTTPClient
  }

-- | Create a new scheduler bridge
createSchedulerBridge :: CLIConfig -> IO SchedulerBridge
createSchedulerBridge config = do
  http <- createHTTPClient (configHost config) (configPort config) (configToken config) (configTimeout config) (configProxy config)
  return $ SchedulerBridge config http

--------------------------------------------------------------------------------
-- Session Operations
--------------------------------------------------------------------------------

-- | Create a session on the orchestration layer.
createSession :: SchedulerBridge -> IO (Either CLIError SessionId)
createSession bridge = do
  result <- httpPost (bridgeHTTP bridge) "/api/session/start" (object ["mode" .= ("standard" :: Text)])
  return $ case result of
    Right (Object r) -> case parseMaybe (.: "sessionId") r of
      Just sessionId -> Right sessionId
      Nothing -> Left $ ValidationError "Missing sessionId in response"
    Right _ -> Left $ ValidationError "Invalid session/start response"
    Left err -> Left err

-- | List all sessions (id strings extracted from session objects).
listSessions :: SchedulerBridge -> IO (Either CLIError [SessionId])
listSessions bridge = do
  result <- httpGet (bridgeHTTP bridge) "/api/sessions" :: IO (Either CLIError [Value])
  return $ case result of
    Right sessions ->
      Right [ sid | Object o <- sessions, Just sid <- [parseMaybe (.: "id") o] ]
    Left err -> Left err

-- | Get a session by ID.  The orchestration layer returns a session
-- object (not a 'SessionEvent'); kept as an explicit error until the CLI
-- side defines a matching projection type.
getSession :: SchedulerBridge -> SessionId -> IO (Either CLIError SessionEvent)
getSession _ _ =
  return $ Left $ UnknownCLIError "getSession: not wired to orchestration API"

-- | Delete a session.
deleteSession :: SchedulerBridge -> SessionId -> IO (Either CLIError ())
deleteSession bridge sessionId = do
  result <- httpDelete (bridgeHTTP bridge) ("/api/session/" ++ sessionId) :: IO (Either CLIError Value)
  return $ fmap (const ()) result

--------------------------------------------------------------------------------
-- Message Operations
--------------------------------------------------------------------------------

-- | Send one user message and return the agent's reply as a stream chunk.
-- The orchestration layer performs the full step and returns aggregated
-- text; delta events will come over SSE later.
sendMessage :: SchedulerBridge -> SessionId -> Text -> IO (Either CLIError StreamChunk)
sendMessage bridge sessionId content =
  fmap (fmap fst) (sendMessageWithUsage bridge sessionId content)

-- | 'sendMessage' plus the orchestration layer's usage echo, when it
-- provides one (turn out + cumulative totals; absent from older kernels).
sendMessageWithUsage
  :: SchedulerBridge -> SessionId -> Text
  -> IO (Either CLIError (StreamChunk, Maybe Usage))
sendMessageWithUsage bridge sessionId content =
  sendMessageWithTarget bridge sessionId Nothing Nothing content

-- | 'sendMessageWithUsage' with an explicit provider/model target.  The
-- scheduler forwards both to the kernel, which picks that provider's
-- adapter for this turn (an unknown provider is a coded kernel refusal).
-- Omitting them leaves the kernel's in-use provider in charge.
sendMessageWithTarget
  :: SchedulerBridge -> SessionId -> Maybe Text -> Maybe Text -> Text
  -> IO (Either CLIError (StreamChunk, Maybe Usage))
sendMessageWithTarget bridge sessionId mprovider mmodel content = do
  let body = object $
        [ "sessionId" .= sessionId, "message" .= content ]
        ++ [ "provider" .= p | Just p <- [mprovider] ]
        ++ [ "model" .= m | Just m <- [mmodel] ]
  result <- httpPost (bridgeHTTP bridge) "/api/agent/step" body
    :: IO (Either CLIError Value)
  return $ case result of
    Right (Object r) -> case parseMaybe (.: "reply") r of
      Just reply -> Right (ChunkDelta reply, usageOf r)
      Nothing    -> Left $ ValidationError "Missing reply in response"
    Right _ -> Left $ ValidationError "Invalid agent/step response"
    Left err -> Left err
  where
    usageOf r = case parseMaybe (.: "usage") r of
      Just v  -> case fromJSON v of Success u -> Just u; _ -> Nothing
      Nothing -> Nothing

-- | The kernel's provider registry (through the scheduler's forward).
listProviders :: SchedulerBridge -> IO (Either CLIError [ProviderInfo])
listProviders bridge = do
  result <- httpGet (bridgeHTTP bridge) "/api/providers"
    :: IO (Either CLIError Value)
  return (result >>= providerStoreToList)

-- | Fetch the stored message list of a session.
getMessages :: SchedulerBridge -> SessionId -> IO (Either CLIError [Message])
getMessages bridge sessionId = do
  result <- httpGet (bridgeHTTP bridge) ("/api/session/" ++ sessionId ++ "/messages")
  return $ case result of
    Right (Object r) -> case parseMaybe (.: "messages") r of
      Just raw -> Right [ msg | Object m <- raw, Just msg <- [parseStored m] ]
      Nothing -> Left $ ValidationError "Missing messages"
    Right _ -> Left $ ValidationError "Invalid session messages response"
    Left err -> Left err
  where
    parseStored :: Object -> Maybe Message
    parseStored o = Message <$> parseMaybe (.: "role") o <*> parseMaybe (.: "content") o

-- | The session's team tasks (the agent's TODO list).  Older schedulers do
-- not include the field; that is an empty list, not an error.
fetchTeamTasks :: SchedulerBridge -> SessionId -> IO (Either CLIError [TodoItem])
fetchTeamTasks bridge sessionId = do
  result <- httpGet (bridgeHTTP bridge) ("/api/session/" ++ sessionId)
              :: IO (Either CLIError Value)
  return $ case result of
    Right (Object r) -> Right (fromMaybe [] (parseMaybe (.: "teamTasks") r))
    Right _          -> Left $ ValidationError "Invalid session response"
    Left err         -> Left err

--------------------------------------------------------------------------------
-- Session Events (SSE)
--------------------------------------------------------------------------------

-- | Subscribe to a session's SSE event stream (Phase 2 S2 tool events).
-- Feed chunks through 'Core.SSE', deliver decoded 'ToolEvent's to the
-- callback.  Returns a cancellation action that stops the reader thread
-- (safe to call from any thread; call it before quitting).
subscribeSessionEvents
  :: SchedulerBridge -> SessionId
  -> (Either CLIError ToolEvent -> IO ())
  -> IO (IO ())
subscribeSessionEvents bridge sid onEvent =
  subscribeSessionEventsWith bridge sid onEvent (const (return ()))

-- | Like 'subscribeSessionEvents' with a second sink for assistant text
-- deltas.  Deltas stream the answer while it is generated; the synchronous
-- @/api/agent/step@ reply remains the terminal signal — a caller that consumes
-- deltas must not also render the full reply (it would duplicate the text).
subscribeSessionEventsWith
  :: SchedulerBridge -> SessionId
  -> (Either CLIError ToolEvent -> IO ())
  -> (Text -> IO ())
  -> IO (IO ())
subscribeSessionEventsWith bridge sid onEvent onDelta =
  subscribeSessionEventsWithTerminal bridge sid onEvent onDelta (return ())

-- | Like 'subscribeSessionEventsWith', plus a third sink fired when the
-- turn's terminal marker arrives (the assistant message echo or the plan
-- gate).  One stream preserves order, so by then every tool update of that
-- turn has already been delivered — callers can tear the stream down
-- without a sleep.
subscribeSessionEventsWithTerminal
  :: SchedulerBridge -> SessionId
  -> (Either CLIError ToolEvent -> IO ())
  -> (Text -> IO ())
  -> IO ()
  -> IO (IO ())
subscribeSessionEventsWithTerminal bridge sid onEvent onDelta onTerminal = do
  let client = bridgeHTTP bridge
      url    = buildUrl client ("/api/events/" ++ sid)
  request <- parseRequest url
  let headers = ("Accept", "text/event-stream") : authHeaders (httpClientToken client)
      request' = request { requestHeaders = headers }
  -- A private manager per subscription.  Cancelling the reader kills a
  -- thread that may be inside the manager's connection accounting; doing
  -- that on the shared manager left the next turn's step request waiting
  -- forever (the server had answered, the client never woke up).  The
  -- stream targets the loopback scheduler, so no proxy and no timeout.
  mgr <- newManager (managerSetProxy noProxy
          (tlsManagerSettings { managerResponseTimeout = responseTimeoutNone }))
  ready <- newEmptyMVar
  tid <- forkIO $
    catch
      (withResponse request' mgr $ \resp -> do
         -- headers received: the server has registered our stream, so
         -- events emitted from this point on will reach us
         putMVar ready ()
         readLoop newDecoder (responseBody resp))
      (\e -> onEvent (Left (UnknownCLIError ("SSE error: " <> T.pack (show (e :: IOError))))))
  -- bounded wait for the handshake so callers can subscribe before the
  -- request that triggers the events they care about
  _ <- timeout 2000000 (takeMVar ready)
  return $ killThread tid
  where
    readLoop :: SseDecoder -> BodyReader -> IO ()
    readLoop dec br = do
      chunk <- brRead br
      if BS.null chunk
        then return ()
        else do
          let (payloads, dec') = feed dec chunk
          mapM_ deliver payloads
          readLoop dec' br
    -- One stream carries tool progress, assistant text deltas and message
    -- echoes. Tool progress and text deltas go to their own sinks; the
    -- message echo is redundant with the synchronous step reply.
    deliver raw = case classifyPayload raw of
      SseTool ev       -> onEvent (Right ev)
      SseTextDelta t   -> case eitherDecodeStrict' t of
        Right (Object o)
          | Just (String txt) <- KM.lookup "text" o -> onDelta txt
        _ -> onEvent (Left (ValidationError ("malformed text delta: " <> snippet t)))
      SseMessage role  -> when (role == "assistant") onTerminal
      SsePlan          -> onTerminal -- the parked turn ends here
      SseUnknown p     ->
        onEvent (Left (ValidationError ("unrecognised SSE payload: " <> snippet p)))
    snippet = T.take 120 . TE.decodeUtf8With (\_ _ -> Just '?')

    authHeaders :: Text -> [(HeaderName, ByteString)]
    authHeaders t
      | T.null t = []
      | otherwise = [("Authorization", "Bearer " <> TE.encodeUtf8 t)]

--------------------------------------------------------------------------------
-- Plan / Approval (Phase 2 S1)
--------------------------------------------------------------------------------

-- | Submit a plan request through the approval gate.  The orchestration
-- layer holds the message and answers with @awaiting_approval@.
planStep :: SchedulerBridge -> SessionId -> Text -> IO (Either CLIError PlanSubmit)
planStep bridge sessionId message = do
  result <- httpPost (bridgeHTTP bridge) "/api/agent/step"
    (object [ "sessionId" .= sessionId, "message" .= message, "requireApproval" .= True ])
    :: IO (Either CLIError Value)
  return $ case result of
    Right (Object r) ->
      case parseMaybe (.: "status") r :: Maybe Text of
        Just "awaiting_approval" ->
          case parseMaybe (.: "pending") r :: Maybe Value of
            Just (Object po) -> case parseMaybe (.: "message") po :: Maybe Text of
              Just msg -> Right (PlanAwaiting msg)
              Nothing  -> Left $ ValidationError "Missing pending.message"
            _ -> Left $ ValidationError "Missing pending"
        Just other -> Left $ ValidationError $ "Unexpected plan status: " <> other
        Nothing -> Left $ ValidationError "Missing status"
    Right _ -> Left $ ValidationError "Invalid plan response"
    Left err -> Left err

--------------------------------------------------------------------------------
-- Multi-step plans (kernel-owned)
--
-- The kernel holds the steps, the phase and the barrier; these calls only
-- relay. Every response carries the whole plan back, so the shell can render
-- the card from the answer instead of keeping its own copy in sync.
--------------------------------------------------------------------------------

-- | Submit a stepwise plan. Steps are titles; the kernel numbers them.
submitPlan :: SchedulerBridge -> SessionId -> [Text] -> IO (Either CLIError PlanView)
submitPlan bridge sessionId stepTitles = do
  let body = object
        [ "mode"  .= ("stepwise" :: Text)
        , "steps" .= [ object [ "title" .= t ] | t <- stepTitles ]
        ]
  result <- httpPost (bridgeHTTP bridge)
    ("/api/session/" ++ sessionId ++ "/plan") body :: IO (Either CLIError Value)
  pure (result >>= planViewOr)

-- | Read the current plan (also works after a restart: the kernel persists it).
fetchPlan :: SchedulerBridge -> SessionId -> IO (Either CLIError PlanView)
fetchPlan bridge sessionId = do
  result <- httpGet (bridgeHTTP bridge) ("/api/session/" ++ sessionId ++ "/plan")
  pure (result >>= planViewOr)

-- | One decision on the pending step: approve, skip, reject or abandon.
decideStep :: SchedulerBridge -> SessionId -> Text -> IO (Either CLIError PlanView)
decideStep bridge sessionId action = do
  result <- httpPost (bridgeHTTP bridge)
    ("/api/session/" ++ sessionId ++ "/decision") (object ["action" .= action])
    :: IO (Either CLIError Value)
  pure (result >>= planViewOr)

-- | Report how an approved step went. The kernel will not guess: until this
-- arrives the step stays "approved" and the plan stays in its executing phase.
reportStep :: SchedulerBridge -> SessionId -> Text -> Bool -> IO (Either CLIError PlanView)
reportStep bridge sessionId stepId ok = do
  result <- httpPost (bridgeHTTP bridge)
    ("/api/session/" ++ sessionId ++ "/step-result")
    (object ["stepId" .= stepId, "ok" .= ok]) :: IO (Either CLIError Value)
  pure (result >>= planViewOr)

planViewOr :: Value -> Either CLIError PlanView
planViewOr v = case parsePlanView v of
  Just pv -> Right pv
  Nothing -> Left $ ValidationError "Invalid plan response"

-- | Approve the pending plan; returns the agent reply.
approvePlan :: SchedulerBridge -> SessionId -> IO (Either CLIError PlanVerdict)
approvePlan bridge sessionId = decidePlan bridge sessionId True

-- | Deny the pending plan.
denyPlan :: SchedulerBridge -> SessionId -> IO (Either CLIError PlanVerdict)
denyPlan bridge sessionId = decidePlan bridge sessionId False

-- | Shared implementation of POST /api/session/:id/decision.
decidePlan :: SchedulerBridge -> SessionId -> Bool -> IO (Either CLIError PlanVerdict)
decidePlan bridge sessionId approve = do
  result <- httpPost (bridgeHTTP bridge) ("/api/session/" ++ sessionId ++ "/decision")
    (object ["approve" .= approve])
    :: IO (Either CLIError Value)
  return $ case result of
    Right (Object r) ->
      case parseMaybe (.: "status") r :: Maybe Text of
        Just "approved" ->
          case parseMaybe (.: "reply") r :: Maybe Text of
            Just reply -> Right (PlanApproved reply)
            Nothing    -> Left $ ValidationError "Missing reply"
        Just "denied"  -> Right PlanDenied
        Just other     -> Left $ ValidationError $ "Unexpected decision status: " <> other
        Nothing        -> Left $ ValidationError "Missing status"
    Right _ -> Left $ ValidationError "Invalid decision response"
    Left err -> Left err

-- | "Allow always" (MiMo's permission bar): append an allow rule for the
-- pending tool to the orchestration layer's permission set.
--
-- Pattern: @Bash(command:<cmd>*)@ when the call carries a command argument,
-- otherwise the bare tool name.
allowAlways :: SchedulerBridge -> ToolName -> [Text] -> IO (Either CLIError ())
allowAlways bridge name args = do
  cur <- httpGet (bridgeHTTP bridge) "/api/permissions"
    :: IO (Either CLIError Value)
  case cur of
    Right (Object r) -> case parseMaybe (.: "rules") r :: Maybe [Value] of
      Just rs -> do
        let rule = object ["kind" .= ("allow" :: Text), "pattern" .= patternOf]
        put <- httpPut (bridgeHTTP bridge) "/api/permissions"
                 (object ["rules" .= (rs ++ [rule])]) :: IO (Either CLIError Value)
        return $ void put
      Nothing -> return $ Left $ ValidationError "Missing rules in permissions response"
    Right _ -> return $ Left $ ValidationError "Invalid permissions response"
    Left err -> return $ Left err
  where
    patternOf
      | name `elem` (["bash", "shell", "run_shell"] :: [ToolName])
      , (c : _) <- args = "Bash(command:" <> T.replace "*" "\\*" c <> "*)"
      | otherwise       = T.pack name

-- | Ask the scheduler to stop the session's in-flight turn.
--
-- The kernel checks the abort flag between tool rounds; an idle session is
-- left untouched (the endpoint refuses rather than setting a flag that would
-- abort the *next* turn).  @Right False@ therefore means "nothing to stop".
interruptSession :: SchedulerBridge -> SessionId -> IO (Either CLIError Bool)
interruptSession bridge sessionId = do
  result <- httpPost (bridgeHTTP bridge) ("/api/session/" ++ sessionId ++ "/interrupt")
              (object []) :: IO (Either CLIError Value)
  return $ case result of
    Right (Object r) -> Right (fromMaybe False (parseMaybe (.: "aborted") r))
    Right _          -> Left $ ValidationError "Invalid interrupt response"
    Left err         -> Left err

--------------------------------------------------------------------------------
-- Agent Operations (no counterpart in the orchestration API yet)
--------------------------------------------------------------------------------

getAgentState :: SchedulerBridge -> AgentId -> IO (Either CLIError AgentState)
getAgentState _ _ =
  return $ Left $ UnknownCLIError "getAgentState: not wired to orchestration API"

updateAgentState :: SchedulerBridge -> AgentId -> AgentState -> IO (Either CLIError ())
updateAgentState _ _ _ =
  return $ Left $ UnknownCLIError "updateAgentState: not wired to orchestration API"

--------------------------------------------------------------------------------
-- Model Operations
--------------------------------------------------------------------------------

-- | List available models (name/description/contextSize from orchestration).
listModels :: SchedulerBridge -> IO (Either CLIError [ModelInfo])
listModels bridge = do
  result <- httpGet (bridgeHTTP bridge) "/api/models" :: IO (Either CLIError [Value])
  return $ case result of
    Right raw -> Right [ mi | Object m <- raw, Just mi <- [parseModel m] ]
    Left err -> Left err
  where
    parseModel :: Object -> Maybe ModelInfo
    parseModel o = ModelInfo
      <$> parseMaybe (.: "name") o
      <*> parseMaybe (.: "description") o
      <*> parseMaybe (.: "contextSize") o

-- | Fetch a single model by name (no dedicated endpoint; explicit error).
getModel :: SchedulerBridge -> Text -> IO (Either CLIError ModelInfo)
getModel _ _ =
  return $ Left $ UnknownCLIError "getModel: not wired to orchestration API"

--------------------------------------------------------------------------------
-- Plugins (Phase 3)
--------------------------------------------------------------------------------

-- | List plugins registered on the orchestration layer.
listPlugins :: SchedulerBridge -> IO (Either CLIError [PluginInfo])
listPlugins bridge = do
  result <- httpGet (bridgeHTTP bridge) "/api/plugins" :: IO (Either CLIError [PluginInfo])
  return $ case result of
    Right ps -> Right ps
    Left err -> Left err

--------------------------------------------------------------------------------
-- Health Check
--------------------------------------------------------------------------------

-- | Check the orchestration service health endpoint.
healthCheck :: SchedulerBridge -> IO (Either CLIError Bool)
healthCheck bridge = do
  result <- httpGet (bridgeHTTP bridge) "/health" :: IO (Either CLIError Value)
  return $ case result of
    Right (Object r) ->
      case parseMaybe (.: "status") r :: Maybe Text of
        Just s  -> Right (s == "ok")
        Nothing -> Left $ ValidationError "Missing status"
    Right _ -> Left $ ValidationError "Invalid health response"
    Left err -> Left err
