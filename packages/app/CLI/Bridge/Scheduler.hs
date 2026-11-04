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
  , submitExperiment
  , setSessionCwd
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
  , listTools
  , fetchPermissions

    -- * Health Check
  , healthCheck
  ) where

import Bridge.Scheduler.Core (SchedulerBridge(..), createSchedulerBridge)
import Bridge.Scheduler.Session
  ( SessionInfo(..), allowAlways, applySessionMode, branchSession, btwAsk
  , compactSession, createSession, deleteSession, fetchQueue, fetchSessionInfo
  , fetchSessionMode, fetchTeamTasks, forkSession, getMessages, getSession
  , interruptSession, listSessions, queueMessage, recapSession, renameSession
  , retrySession, sendMessage, sendMessageWithEffort, sendMessageWithTarget
  , sendMessageWithTargetEffort, sendMessageWithUsage, setSessionCwd, steerSession
  , subscribeSessionEvents, subscribeSessionEventsWith
  , subscribeSessionEventsWithTerminal, tagSession )
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
import System.Directory (getCurrentDirectory)
import System.Timeout (timeout)
import Control.Exception (SomeAsyncException, SomeException, catch, fromException, throwIO)
import Data.Text (Text)
import qualified Data.Vector as V
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Network.HTTP.Client
    ( BodyReader, HttpException(..), managerResponseTimeout, managerSetProxy, newManager, noProxy
    , parseRequest, requestHeaders, responseBody, responseTimeoutNone, withResponse, brRead
    )
import Network.HTTP.Types (HeaderName)

-- | Scheduler bridge
-- Session Operations
--------------------------------------------------------------------------------


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

-- | Submit an experiment batch (T2.7): the scheduler runs the variants ×
-- seeds matrix and returns {batchId, results, reproPath}. The CLI has no
-- sandbox executor of its own — the batching, retries and audit tags live
-- behind /api/sandbox/experiment by design (ADR-002: execution belongs to
-- the scheduling layer).
submitExperiment :: SchedulerBridge -> Value -> IO (Either CLIError Value)
submitExperiment bridge payload =
  httpPost (bridgeHTTP bridge) "/api/sandbox/experiment" payload








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

-- | The scheduler's tool catalog (@GET /api/tools@), optionally filtered by
-- preset mode (@standard|ptc|minimal|cordis@).
listTools :: SchedulerBridge -> Maybe Text -> IO (Either CLIError [Value])
listTools bridge mmode = do
  r <- httpGet (bridgeHTTP bridge)
         ("/api/tools" <> maybe "" (\m -> "?mode=" <> T.unpack m) mmode)
  return $ case r of
    Right (Array a) -> Right (V.toList a)
    Right _ -> Left (ValidationError "Invalid tools response")
    Left e -> Left e

-- | The orchestration layer's permission rules (@GET /api/permissions@).
fetchPermissions :: SchedulerBridge -> IO (Either CLIError [Value])
fetchPermissions bridge = do
  r <- httpGet (bridgeHTTP bridge) "/api/permissions"
  return $ case r of
    Right (Object o) -> case KM.lookup "rules" o of
      Just (Array a) -> Right (V.toList a)
      _ -> Left (ValidationError "Missing rules in permissions response")
    Right _ -> Left (ValidationError "Invalid permissions response")
    Left e -> Left e

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
