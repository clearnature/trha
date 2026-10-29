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
  , sendMessageWithTargetEffort
  , sendMessageWithEffort
  , getMessages
  , allowAlways
  , interruptSession
  , fetchTeamTasks
  , SessionInfo(..)
  , fetchSessionInfo
  , fetchAgents
  , renameSession
  , tagSession
  , fetchServiceStatus
  , fetchBalance
  , fetchUsageStats
  , UsageRow(..)
  , transcribeVoice
  , compactSession
  , retrySession
  , btwAsk
  , recapSession
  , queueMessage
  , fetchQueue
  , steerSession
  , forkSession
  , branchSession
  , setInUseProvider
  , setSandboxConfig
  , fetchSandboxConfig
  , startLoop
  , fetchLoops
  , stopLoops
  , listWorkflows
  , runWorkflow
  , SessionMode(..)
  , fetchSessionMode
  , applySessionMode
  , listProviders
  , probeProvider
  , ProviderProbe(..)
  , saveProvider
  , removeProvider

    -- * Session Events (SSE, Phase 2 S2)
  , subscribeSessionEvents
  , subscribeSessionEventsWith
  , subscribeSessionEventsWithTerminal

    -- * Plan / Approval (Phase 2 S1)
  , planStep
  , approvePlan
  , denyPlan
  , denyPlanWithReason

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

import Config.Settings (resolveConfig)
import Core.Types
import Core.RunState (RuntimeEntry(..), Service(..), readRuntimeEntry)
import Core.HTTP
import Core.SSE (SseDecoder, SsePayload(..), SseNotice(..), classifyPayload, toNotice, feed, newDecoder)
import Data.Aeson
import qualified Data.Aeson.KeyMap as KM
import Data.Aeson.Types (parseMaybe, (.:), (.:?), (.!=))
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Control.Concurrent (forkIO, killThread, newEmptyMVar, putMVar, takeMVar)
import Control.Monad (join, void, when)
import Data.Maybe (fromMaybe)
import System.Timeout (timeout)
import Control.Exception (SomeAsyncException, SomeException, catch, fromException, throwIO)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Network.HTTP.Client
    ( BodyReader, HttpException(..), managerResponseTimeout, managerSetProxy, newManager, noProxy
    , parseRequest, requestHeaders, responseBody, responseTimeoutNone, withResponse, brRead
    )
import Network.HTTP.Types (HeaderName)

-- | Scheduler bridge
data SchedulerBridge = SchedulerBridge
  { bridgeConfig :: CLIConfig
  , bridgeHTTP   :: HTTPClient
  }

-- | Create a new scheduler bridge
createSchedulerBridge :: CLIConfig -> IO SchedulerBridge
createSchedulerBridge config = do
  -- The scheduler publishes its live endpoint in ~/.trha/runtime.json; use it
  -- when the caller left the defaults in place.
  rt <- readRuntimeEntry Scheduler
  let cfg = case rt of
        Just e | configPort config == 28433 ->
          config
            { configHost  = T.pack (reHost e)
            , configPort  = rePort e
            , configToken = if T.strip (configToken config) == "dev-token"
                              then T.pack (reToken e)
                              else configToken config
            }
        _ -> config
  http <- createHTTPClient (configScheme cfg) (configHost cfg) (configPort cfg) (configToken cfg) (configTimeout cfg) (configProxy cfg)
  return $ SchedulerBridge cfg http

--------------------------------------------------------------------------------
-- Session Operations
--------------------------------------------------------------------------------

-- | Create a session on the orchestration layer.
createSession :: SchedulerBridge -> IO (Either CLIError SessionId)
createSession bridge = do
  cfg <- resolveConfig defaultCLIConfig
  result <- httpPost (bridgeHTTP bridge) "/api/session/start"
    (object [ "mode" .= ("standard" :: Text)
            , "askTimeout" .= configAskTimeout cfg ])
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
sendMessageWithTarget bridge sessionId mprovider mmodel content =
  sendMessageWithTargetEffort bridge sessionId mprovider mmodel Nothing Nothing content

-- | Like 'sendMessageWithTarget' but carries a reasoning effort, which the
-- scheduler forwards to the kernel as @genParams.effort@.
sendMessageWithEffort
  :: SchedulerBridge -> SessionId -> Maybe Text -> Maybe Text -> Text
  -> IO (Either CLIError (StreamChunk, Maybe Usage))
sendMessageWithEffort bridge sessionId meffort mlang content =
  sendMessageWithTargetEffort bridge sessionId Nothing Nothing meffort mlang content

sendMessageWithTargetEffort
  :: SchedulerBridge -> SessionId -> Maybe Text -> Maybe Text -> Maybe Text -> Maybe Text -> Text
  -> IO (Either CLIError (StreamChunk, Maybe Usage))
sendMessageWithTargetEffort bridge sessionId mprovider mmodel meffort mlang content = do
  let body = object $
        [ "sessionId" .= sessionId, "message" .= content ]
        ++ [ "provider" .= p | Just p <- [mprovider] ]
        ++ [ "model" .= m | Just m <- [mmodel] ]
        ++ [ "effort" .= e | Just e <- [meffort] ]
        ++ [ "reasoningLanguage" .= l | Just l <- [mlang] ]
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

-- | Ask an endpoint what it is (@POST /api/providers/probe@).  The kernel
-- classifies the model listing; the caller confirms every field.
probeProvider
  :: SchedulerBridge -> Text -> Text
  -> IO (Either CLIError ProviderProbe)
probeProvider bridge baseUrl apiKey = do
  let body = object [ "baseUrl" .= baseUrl, "apiKey" .= apiKey ]
  r <- httpPost (bridgeHTTP bridge) "/api/providers/probe" body
    :: IO (Either CLIError Value)
  return $ case r of
    Right v  -> case fromJSON v of
      Success p -> Right p
      _         -> Left (ValidationError "Invalid probe response")
    Left err -> Left err

-- | Save (or overwrite) one provider.  An empty @apiKey@ keeps the stored
-- key (the kernel treats a blank key as "unchanged").
saveProvider
  :: SchedulerBridge -> Text -> Text -> Text -> Text -> [Text] -> Text
  -> Bool -> Bool -> Text -> [Text] -> [Text]
  -> Maybe Value -> Maybe Value -> Text -> Text -> Maybe Int
  -> IO (Either CLIError [ProviderInfo])
saveProvider bridge name kind baseUrl apiKey models def authHeader noProxy effort vision efforts
             headers extraBody thinking responsesMode contextWindow = do
  let body = object
        [ "name" .= name
        , "kind" .= kind
        , "baseUrl" .= baseUrl
        , "apiKey" .= apiKey
        , "models" .= models
        , "default" .= def
        , "authHeader" .= authHeader
        , "noProxy" .= noProxy
        , "effort" .= effort
        , "efforts" .= efforts
        , "vision" .= vision
        , "headers" .= headers
        , "extraBody" .= extraBody
        , "thinking" .= thinking
        , "responsesMode" .= responsesMode
        , "contextWindow" .= contextWindow
        ]
  result <- httpPost (bridgeHTTP bridge) "/api/providers" body
    :: IO (Either CLIError Value)
  return (result >>= providerStoreToList)

-- | Remove one provider by name.
removeProvider :: SchedulerBridge -> Text -> IO (Either CLIError [ProviderInfo])
removeProvider bridge name = do
  result <- httpPost (bridgeHTTP bridge) "/api/providers/remove"
              (object ["name" .= name]) :: IO (Either CLIError Value)
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

-- | Sessions with their parent links (sidebar agent tree).
fetchAgents :: SchedulerBridge -> IO (Either CLIError [AgentEntry])
fetchAgents bridge = do
  result <- httpGet (bridgeHTTP bridge) "/api/sessions" :: IO (Either CLIError [Value])
  return $ case result of
    Right rows -> Right [ e | Just e <- map parseMaybeAgent rows ]
    Left err   -> Left err
  where
    parseMaybeAgent (Object o) =
      case parseMaybe (.: "id") o of
        Just sid -> Just AgentEntry { aeId = sid, aeParent = join (parseMaybe (.:? "parentId") o) }
        Nothing  -> Nothing
    parseMaybeAgent _ = Nothing

-- | One GET for the sidebar's goal and TODO sections.
fetchSessionInfo :: SchedulerBridge -> SessionId -> IO (Either CLIError SessionInfo)
fetchSessionInfo bridge sid = do
  result <- httpGet (bridgeHTTP bridge) ("/api/session/" ++ sid)
              :: IO (Either CLIError Value)
  return $ case result of
    Right (Object r) -> Right SessionInfo
      { siGoal = case KM.lookup "goal" r of
          Just (Object g) -> parseMaybe (.: "objective") g
          _               -> Nothing
      , siTodos = fromMaybe [] (parseMaybe (.: "teamTasks") r)
      }
    Right _  -> Left $ ValidationError "Invalid session response"
    Left err -> Left err

-- | Read the session's current posture.
fetchSessionMode :: SchedulerBridge -> SessionId -> IO (Either CLIError SessionMode)
fetchSessionMode bridge sid =
  httpGet (bridgeHTTP bridge) ("/api/session/" ++ sid ++ "/mode")

-- | Apply one posture action: @cycle@ (Shift+Tab), @yolo@ (Ctrl+Y), or @set@.
applySessionMode :: SchedulerBridge -> SessionId -> Value -> IO (Either CLIError SessionMode)
applySessionMode bridge sid body =
  httpPost (bridgeHTTP bridge) ("/api/session/" ++ sid ++ "/mode") body

-- | Rename a session (user-facing title; persisted server-side).
renameSession :: SchedulerBridge -> SessionId -> Text -> IO (Either CLIError Value)
renameSession bridge sid title =
  httpPost (bridgeHTTP bridge) ("/api/session/" ++ sid ++ "/meta")
    (object ["title" .= title])

-- | Replace a session's tags.
tagSession :: SchedulerBridge -> SessionId -> [Text] -> IO (Either CLIError Value)
tagSession bridge sid tags =
  httpPost (bridgeHTTP bridge) ("/api/session/" ++ sid ++ "/meta")
    (object ["tags" .= tags])

-- | Built-in workflow templates (/workflow).
listWorkflows :: SchedulerBridge -> IO (Either CLIError [(Text, Text)])
listWorkflows bridge = do
  r <- httpGet (bridgeHTTP bridge) "/api/workflows"
  pure $ case r of
    Left e  -> Left e
    Right v -> Right
      [ (n, d)
      | Just (Object o) <- map Just (fromMaybe [] (parseMaybe (.: "workflows") v))
      , Just n <- [parseMaybe (.: "name") o]
      , Just d <- [parseMaybe (.: "description") o] ]

-- | Run a workflow template in this session.
runWorkflow :: SchedulerBridge -> SessionId -> Text -> Text -> IO (Either CLIError Text)
runWorkflow bridge sid name input = do
  r <- httpPost (bridgeHTTP bridge) ("/api/session/" ++ sid ++ "/workflow")
         (object ["name" .= name, "input" .= input])
  pure $ case r of
    Left e  -> Left e
    Right v -> case parseMaybe (.: "reply") v of
      Just t  -> Right t
      Nothing -> Left (ServerError "workflow returned no reply")

-- | Start a recurring prompt (/loop).
startLoop :: SchedulerBridge -> SessionId -> Int -> Text -> IO (Either CLIError Text)
startLoop bridge sid intervalMs prompt = do
  r <- httpPost (bridgeHTTP bridge) ("/api/session/" ++ sid ++ "/loop")
         (object ["interval" .= intervalMs, "prompt" .= prompt])
  pure $ case r of
    Left e  -> Left e
    Right v -> case parseMaybe (.: "id") v of
      Just i  -> Right i
      Nothing -> Left (ServerError "loop returned no id")

-- | Active loops of a session.
fetchLoops :: SchedulerBridge -> SessionId -> IO (Either CLIError [Text])
fetchLoops bridge sid = do
  r <- httpGet (bridgeHTTP bridge) ("/api/session/" ++ sid ++ "/loop")
  pure $ case r of
    Left e  -> Left e
    Right v -> Right
      [ p <> "  (" <> T.pack (show (repeatMs :: Int)) <> " ms, " <> T.pack (show (runs :: Int)) <> trhaRuns <> ")"
      | Just (Object o) <- map Just (fromMaybe [] (parseMaybe (.: "loops") v))
      , Just p <- [parseMaybe (.: "prompt") o]
      , Just repeatMs <- [parseMaybe (.: "repeatMs") o]
      , Just runs <- [parseMaybe (.: "runs") o] ]
  where trhaRuns = " runs" :: Text

-- | Cancel every active loop of a session.
stopLoops :: SchedulerBridge -> SessionId -> IO (Either CLIError Int)
stopLoops bridge sid = do
  r <- httpPost (bridgeHTTP bridge) ("/api/session/" ++ sid ++ "/loop") (object ["stop" .= True])
  pure $ case r of
    Left e  -> Left e
    Right v -> case parseMaybe (.: "cancelled") v of
      Just n  -> Right n
      Nothing -> Left (ServerError "loop stop returned no count")

-- | Make one saved provider the active one (/switch).
setInUseProvider :: SchedulerBridge -> Text -> IO (Either CLIError [ProviderInfo])
setInUseProvider bridge name = do
  r <- httpPost (bridgeHTTP bridge) "/api/providers/in-use" (object ["name" .= name])
  pure $ case r of
    Left e  -> Left e
    Right v -> providerStoreToList v

-- | Read the scheduler's effective sandbox switch (/sandbox badge).
fetchSandboxConfig :: SchedulerBridge -> IO (Either CLIError Bool)
fetchSandboxConfig bridge = do
  r <- httpGet (bridgeHTTP bridge) "/api/sandbox/config" :: IO (Either CLIError Value)
  pure $ case r of
    Left e -> Left e
    Right (Object o) -> Right (fromMaybe False (parseMaybe (.: "enabled") o))
    Right _ -> Left (ValidationError "invalid sandbox config response")

-- | Persist sandbox settings through the scheduler (/sandbox panel).
setSandboxConfig :: SchedulerBridge -> Bool -> Text -> Text -> Text -> IO (Either CLIError ())
setSandboxConfig bridge enabled policy network scratch = do
  r <- (httpPut (bridgeHTTP bridge) "/api/sandbox/config"
         (object [ "enabled" .= enabled
                 , "policy" .= policy
                 , "network" .= network
                 , "scratch" .= scratch ])) :: IO (Either CLIError Value)
  pure $ case r of
    Left e  -> Left e
    Right _ -> Right ()

-- | Copy this session into a child (/fork); @upto@ truncates the history.
forkSession :: SchedulerBridge -> SessionId -> Maybe Int -> IO (Either CLIError SessionId)
forkSession bridge sid upto = do
  r <- httpPost (bridgeHTTP bridge) ("/api/session/" ++ sid ++ "/fork")
         (object [ "upto" .= n | Just n <- [upto] ])
  pure $ case r of
    Left e  -> Left e
    Right v -> case parseMaybe (.: "id") v of
      Just i  -> Right i
      Nothing -> Left (ServerError "fork returned no id")

-- | Fork just before the last user turn (/branch).
branchSession :: SchedulerBridge -> SessionId -> IO (Either CLIError SessionId)
branchSession bridge sid = do
  r <- httpPost (bridgeHTTP bridge) ("/api/session/" ++ sid ++ "/branch") (object [])
  pure $ case r of
    Left e  -> Left e
    Right v -> case parseMaybe (.: "id") v of
      Just i  -> Right i
      Nothing -> Left (ServerError "branch returned no id")

-- | Inject a prompt into the running turn (/steer).
steerSession :: SchedulerBridge -> SessionId -> Text -> IO (Either CLIError Int)
steerSession bridge sid prompt = do
  r <- httpPost (bridgeHTTP bridge) ("/api/session/" ++ sid ++ "/steer")
         (object ["prompt" .= prompt])
  pure $ case r of
    Left e  -> Left e
    Right v -> case parseMaybe (.: "steered") v of
      Just n  -> Right n
      Nothing -> Left (ServerError "steer returned no count")

-- | Park a message to run after the current turn (/queue).
queueMessage :: SchedulerBridge -> SessionId -> Text -> IO (Either CLIError Int)
queueMessage bridge sid message = do
  r <- httpPost (bridgeHTTP bridge) ("/api/session/" ++ sid ++ "/queue")
         (object ["message" .= message])
  pure $ case r of
    Left e  -> Left e
    Right v -> case parseMaybe (.: "queued") v of
      Just n  -> Right n
      Nothing -> Left (ServerError "queue returned no depth")

-- | Messages currently queued for a session.
fetchQueue :: SchedulerBridge -> SessionId -> IO (Either CLIError [Text])
fetchQueue bridge sid = do
  r <- httpGet (bridgeHTTP bridge) ("/api/session/" ++ sid ++ "/queue")
  pure $ case r of
    Left e  -> Left e
    Right v -> Right
      [ m | Just (Object o) <- map Just (fromMaybe [] (parseMaybe (.: "queued") v))
          , Just m <- [parseMaybe (.: "message") o] ]

-- | Summarize the conversation so far (/recap).
recapSession :: SchedulerBridge -> SessionId -> IO (Either CLIError Text)
recapSession bridge sid = do
  r <- httpPost (bridgeHTTP bridge) ("/api/session/" ++ sid ++ "/recap") (object [])
  pure $ case r of
    Left e  -> Left e
    Right v -> case parseMaybe (.: "summary") v of
      Just t  -> Right t
      Nothing -> Left (ServerError "recap returned no summary")

-- | Ask a side question without touching the conversation (/btw).
btwAsk :: SchedulerBridge -> SessionId -> Text -> IO (Either CLIError Text)
btwAsk bridge sid question = do
  r <- httpPost (bridgeHTTP bridge) ("/api/session/" ++ sid ++ "/btw")
         (object ["question" .= question])
  pure $ case r of
    Left e  -> Left e
    Right v -> case parseMaybe (.: "answer") v of
      Just t  -> Right t
      Nothing -> Left (ServerError "btw returned no answer")

-- | Replay the last turn exactly (/retry).
retrySession :: SchedulerBridge -> SessionId -> IO (Either CLIError Text)
retrySession bridge sid = do
  r <- httpPost (bridgeHTTP bridge) ("/api/session/" ++ sid ++ "/retry") (object [])
  pure $ case r of
    Left e  -> Left e
    Right v -> case parseMaybe (.: "reply") v of
      Just t  -> Right t
      Nothing -> Left (ServerError "retry returned no reply")

-- | Compact a session's history through the scheduler's context governor.
compactSession :: SchedulerBridge -> SessionId -> IO (Either CLIError (Text, Int))
compactSession bridge sid = do
  r <- httpPost (bridgeHTTP bridge) ("/api/session/" ++ sid ++ "/compact") (object [])
  pure $ case r of
    Left e  -> Left e
    Right v -> case parseMaybe (.: "savedTokens") v of
      Just n  -> Right (fromMaybe "none" (parseMaybe (.: "trigger") v), n)
      Nothing -> Left (ServerError "compact returned no result")

-- | Transcribe a recorded WAV through the scheduler (MiMo's ASR contract:
-- chat/completions + input_audio, not /audio/transcriptions).
transcribeVoice :: SchedulerBridge -> Text -> IO (Either CLIError Text)
transcribeVoice bridge path = do
  r <- httpPost (bridgeHTTP bridge) "/api/transcribe" (object ["path" .= path])
  pure $ case r of
    Left e   -> Left e
    Right v  -> case parseMaybe (.: "text") v of
      Just t | not (T.null (T.strip t)) -> Right t
      _ -> Left (ServerError "transcribe returned no text")

-- | Provider account balance (DeepSeek @/user/balance@, via the scheduler).
fetchBalance :: SchedulerBridge -> IO (Either CLIError Balance)
fetchBalance bridge = httpGet (bridgeHTTP bridge) "/api/balance"

-- | One row of @GET /api/usage-stats@: accounting aggregated per session mode.
--
-- The kernel bills @input_cache_hit_tokens@ / @input_cache_miss_tokens@
-- separately, and this row exposes the same split, so the numbers here match
-- the provider's invoice instead of an estimate.
data UsageRow = UsageRow
  { urMode       :: Text
  , urRequests   :: Int
  , urPrompt     :: Int
  , urCompletion :: Int
  , urCacheHit   :: Int
  , urCacheMiss  :: Int
  , urHitRatio   :: Double
  , urResets     :: Int
  , urCost       :: Text
  } deriving (Eq, Show)

instance FromJSON UsageRow where
  parseJSON = withObject "UsageRow" $ \o -> UsageRow
    <$> o .: "model"
    <*> o .:? "requests" .!= 0
    <*> o .:? "promptTokens" .!= 0
    <*> o .:? "completionTokens" .!= 0
    <*> o .:? "cacheHitTokens" .!= 0
    <*> o .:? "cacheMissTokens" .!= 0
    <*> o .:? "cacheHitRatio" .!= 0
    <*> o .:? "contextResets" .!= 0
    <*> o .:? "cost" .!= "—"

fetchUsageStats :: SchedulerBridge -> IO (Either CLIError [UsageRow])
fetchUsageStats bridge = do
  r <- httpGet (bridgeHTTP bridge) "/api/usage-stats"
  pure $ case r of
    Left e -> Left e
    Right v -> case parseMaybe (\o -> o .: "rows") v :: Maybe [UsageRow] of
      Just rows -> Right rows
      Nothing -> Left (ValidationError "Missing rows in /api/usage-stats")

-- | LSP / MCP service state for the sidebar (best effort: [] when the
-- scheduler predates the endpoints).
fetchServiceStatus :: SchedulerBridge -> IO ([Text], [Text])
fetchServiceStatus bridge = do
  mcp <- httpGet (bridgeHTTP bridge) "/api/mcp/status" :: IO (Either CLIError Value)
  lsp <- httpGet (bridgeHTTP bridge) "/api/lsp/status" :: IO (Either CLIError Value)
  return (lspLine lsp, mcpLine mcp)
  where
    mcpLine (Right (Object o)) =
      let configured = fromMaybe [] (join (parseMaybe (.:? "configured") o)) :: [Text]
          connected  = fromMaybe [] (join (parseMaybe (.:? "connected") o)) :: [Text]
      in [ T.pack (show (length connected)) <> "/"
             <> T.pack (show (length configured))
             <> (if null connected then "" else " (" <> T.intercalate "," connected <> ")") ]
    mcpLine _ = []
    lspLine (Right (Object o)) =
      case join (parseMaybe (.:? "running") o) :: Maybe Bool of
        Just True ->
          let diags = fromMaybe 0 (join (parseMaybe (.:? "diagnostics") o)) :: Int
          in ["running" <> (if diags > 0 then " · " <> T.pack (show diags) <> " diags" else "")]
        _ -> []
    lspLine _ = []

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
  subscribeSessionEventsWithTerminal bridge sid onEvent onDelta (return ()) (const (return ()))

-- | Like 'subscribeSessionEventsWith', plus a third sink fired when the
-- turn's terminal marker arrives (the assistant message echo or the plan
-- gate).  One stream preserves order, so by then every tool update of that
-- turn has already been delivered — callers can tear the stream down
-- without a sleep.  The fourth sink carries structured side-channel events
-- (reasoning deltas, step boundaries, context compaction).
subscribeSessionEventsWithTerminal
  :: SchedulerBridge -> SessionId
  -> (Either CLIError ToolEvent -> IO ())
  -> (Text -> IO ())
  -> IO ()
  -> (SseNotice -> IO ())
  -> IO (IO ())
subscribeSessionEventsWithTerminal bridge sid onEvent onDelta onTerminal onNotice = do
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
          ((managerSettingsForBase (httpClientBase client))
             { managerResponseTimeout = responseTimeoutNone }))
  ready <- newEmptyMVar
  tid <- forkIO $
    (withResponse request' mgr $ \resp -> do
       -- headers received: the server has registered our stream, so
       -- events emitted from this point on will reach us
       putMVar ready ()
       readLoop newDecoder (responseBody resp))
      `catch` report
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
      payload
        | Just notice <- toNotice payload -> onNotice notice
      SseMessage role  -> when (role == "assistant") onTerminal
      SsePlan          -> onTerminal -- the parked turn ends here
      SseUnknown p     ->
        onEvent (Left (ValidationError ("unrecognised SSE payload: " <> snippet p)))
    snippet = T.take 120 . TE.decodeUtf8With (\_ _ -> Just '?')

    -- Nothing may escape this thread: an uncaught exception here prints
    -- @trha: Uncaught exception …@ over the TUI.  Cancellation
    -- ('killThread', i.e. 'SomeAsyncException') still propagates; everything
    -- else becomes one error event.
    report :: SomeException -> IO ()
    report e
      | isAsync e             = throwIO e
      | Just he <- fromException e = onEvent (Left (sseError he))
      | otherwise = onEvent (Left (UnknownCLIError ("SSE error: " <> T.pack (show e))))
    isAsync :: SomeException -> Bool
    isAsync e = case fromException e :: Maybe SomeAsyncException of
      Just _  -> True
      Nothing -> False

    -- A failed handshake (wrong scheme, untrusted cert) is an 'HttpException',
    -- which is *not* an 'IOError': the old handler never fired and the reader
    -- thread died with an uncaught exception printed to stderr.  Show the
    -- failure reason only — the full Request dump is 20 lines of internals.
    sseError :: HttpException -> CLIError
    sseError (HttpExceptionRequest _ content) =
      UnknownCLIError ("SSE error: " <> T.pack (show content))
    sseError e = UnknownCLIError ("SSE error: " <> T.pack (show e))

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

-- | Deny the pending plan with a reason (forwarded to the kernel, where it
-- can be shown to the model as the rejection cause).
denyPlanWithReason :: SchedulerBridge -> SessionId -> Text -> IO (Either CLIError PlanVerdict)
denyPlanWithReason bridge sessionId reason = do
  result <- httpPost (bridgeHTTP bridge) ("/api/session/" ++ sessionId ++ "/decision")
    (object ["action" .= ("reject" :: Text), "reason" .= reason])
    :: IO (Either CLIError Value)
  return $ case result of
    Right (Object r) ->
      case parseMaybe (.: "status") r :: Maybe Text of
        Just "rejected" -> Right PlanDenied
        Just other      -> Left $ ValidationError $ "Unexpected decision status: " <> other
        Nothing         -> Left $ ValidationError "Missing status"
    Right _ -> Left $ ValidationError "Unexpected decision payload"
    Left err -> Left err

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
