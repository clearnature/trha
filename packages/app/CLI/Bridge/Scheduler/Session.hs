{-# LANGUAGE OverloadedStrings #-}

-- | 会话端点：创建/列表/删除、发消息（含流式与用量）、消息回放、
-- 重命名/标签、fork/branch、steer/queue、压缩/重试/复述、
-- 会话事件 SSE 订阅、中断与 always-allow。
--
-- 从 "Bridge.Scheduler" 拆出（约定见 "Bridge.Scheduler.Core"）。
module Bridge.Scheduler.Session
  ( createSession, listSessions, getSession, deleteSession
  , sendMessage, sendMessageWithUsage, sendMessageWithTarget
  , sendMessageWithTargetEffort, sendMessageWithEffort
  , getMessages, renameSession, tagSession, fetchSessionInfo, fetchTeamTasks
  , compactSession, retrySession, btwAsk, recapSession
  , queueMessage, fetchQueue, steerSession, forkSession, branchSession
  , setSessionCwd, fetchSessionMode, applySessionMode
  , subscribeSessionEvents, subscribeSessionEventsWith
  , subscribeSessionEventsWithTerminal
  , interruptSession, allowAlways
  , SessionInfo(..)
  ) where

import Bridge.Scheduler.Core (SchedulerBridge(..))
import Config.Settings (resolveConfig)
import Core.Types
import Core.HTTP
import Core.SSE (SseDecoder, SsePayload(..), SseNotice(..), classifyPayload, toNotice, feed, newDecoder)
import Data.Aeson
import qualified Data.Aeson.KeyMap as KM
import Data.Aeson.Types (parseMaybe, (.:), (.:?), (.!=))
import qualified Data.Vector as V
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import System.Directory (getCurrentDirectory)
import System.Timeout (timeout)
import Control.Concurrent (forkIO, killThread, newEmptyMVar, putMVar, takeMVar)
import Control.Monad (join, void, when)
import Control.Exception (SomeAsyncException, SomeException, catch, fromException, throwIO)
import Data.Maybe (fromMaybe)
import Network.HTTP.Client
  ( BodyReader, HttpException(..), brRead, managerResponseTimeout, managerSetProxy
  , newManager, noProxy, parseRequest, requestHeaders, responseBody
  , responseTimeoutNone, withResponse )
import Network.HTTP.Types (HeaderName)

-- | Scheduler bridge
-- | SchedulerBridge 与 createSchedulerBridge 见 Bridge.Scheduler.Core。

-- Session Operations
--------------------------------------------------------------------------------

-- | Create a session on the orchestration layer.
--
-- @cwd@ is the client's own directory: the scheduler serves every client
-- (TUI/desktop/web), so the session — not the process — must say which
-- project it belongs to.
-- | @permissionMode@ 是新会话的初始姿态（read-only/ask/auto/yolo/plan）。
--
-- 之前这里不传：TUI 的 Shift+Tab 只改本地标签，服务端却按缺省的
-- read-only 建会话 —— 状态栏显示 YOLO，工具照样被拒。
createSession :: SchedulerBridge -> Maybe Text -> IO (Either CLIError SessionId)
createSession bridge permissionMode = do
  cfg <- resolveConfig defaultCLIConfig
  cwd <- getCurrentDirectory
  result <- httpPost (bridgeHTTP bridge) "/api/session/start"
    (object ([ "mode" .= ("standard" :: Text)
             , "askTimeout" .= configAskTimeout cfg
             -- The agent preset decides which tools the model is offered; without
             -- it the scheduler falls back to `standard` (the full set).
             , "agentPreset" .= configAgentPreset cfg
             , "cwd" .= T.pack cwd ]
             ++ [ "permissionMode" .= pm | Just pm <- [permissionMode] ]))
  return $ case result of
    Right (Object r) -> case parseMaybe (.: "sessionId") r of
      Just sessionId -> Right sessionId
      Nothing -> Left $ ValidationError "Missing sessionId in response"
    Right _ -> Left $ ValidationError "Invalid session/start response"
    Left err -> Left err

-- | List all sessions (id strings extracted from session objects).

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

-- | Get a session by ID.  The orchestration layer returns a session
-- object (not a 'SessionEvent'); kept as an explicit error until the CLI
-- side defines a matching projection type.
getSession :: SchedulerBridge -> SessionId -> IO (Either CLIError SessionEvent)
getSession _ _ =
  return $ Left $ UnknownCLIError "getSession: not wired to orchestration API"

-- | Delete a session.

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

-- | Read the session's current posture.
fetchSessionMode :: SchedulerBridge -> SessionId -> IO (Either CLIError SessionMode)
fetchSessionMode bridge sid =
  httpGet (bridgeHTTP bridge) ("/api/session/" ++ sid ++ "/mode")

-- | Apply one posture action: @cycle@ (Shift+Tab), @yolo@ (Ctrl+Y), or @set@.

-- | Apply one posture action: @cycle@ (Shift+Tab), @yolo@ (Ctrl+Y), or @set@.
applySessionMode :: SchedulerBridge -> SessionId -> Value -> IO (Either CLIError SessionMode)
applySessionMode bridge sid body =
  httpPost (bridgeHTTP bridge) ("/api/session/" ++ sid ++ "/mode") body

-- | Rename a session (user-facing title; persisted server-side).

-- | Rename a session (user-facing title; persisted server-side).
renameSession :: SchedulerBridge -> SessionId -> Text -> IO (Either CLIError Value)
renameSession bridge sid title =
  httpPost (bridgeHTTP bridge) ("/api/session/" ++ sid ++ "/meta")
    (object ["title" .= title])

-- | Replace a session's tags.

-- | Replace a session's tags.
tagSession :: SchedulerBridge -> SessionId -> [Text] -> IO (Either CLIError Value)
tagSession bridge sid tags =
  httpPost (bridgeHTTP bridge) ("/api/session/" ++ sid ++ "/meta")
    (object ["tags" .= tags])

-- | Built-in workflow templates (/workflow).

-- | Point the session at a different workspace.
--
-- This is the human channel: the model has no tool that reaches this endpoint
-- (its `cd` is clamped to the current workspace), so an agent can never widen
-- its own sandbox. Reached only through the `/workspace` slash command.
setSessionCwd :: SchedulerBridge -> SessionId -> FilePath -> IO (Either CLIError FilePath)
setSessionCwd bridge sid dir = do
  r <- (httpPost (bridgeHTTP bridge) ("/api/session/" ++ sid ++ "/cwd")
         (object [ "cwd" .= T.pack dir ])) :: IO (Either CLIError Value)
  pure $ case r of
    Left e  -> Left e
    Right _ -> Right dir

-- | Copy this session into a child (/fork); @upto@ truncates the history.

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
