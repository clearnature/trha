{-# LANGUAGE OverloadedStrings #-}

-- | Local transcript persistence for CLI sessions.
--
-- A trha session lives on the kernel side, but the CLI keeps a local
-- append-only JSONL mirror under @~/.trha/sessions/<session-id>/
-- transcript.jsonl@ (one JSON event per line), modelled on
-- haskell-agent's per-session directories.
--
-- Layout of one line:
--
-- > {"ts":"2026-09-04T23:30:00Z","event":"user","content":"hello",...}
--
-- 'loadTranscript' skips lines that fail to parse, so an interrupted
-- append never breaks reading.
module Core.Transcript
  ( -- * Recording
    ensureSessionDir
  , recordSession
  , recordUser
  , recordAssistant
  , recordTool
  , recordToolEvent
  , recordDone
  , recordError
  , recordChunk
  , recordModelRequest
    -- * Event registry (single source of truth)
  , EventKind(..)
  , eventKindName
  , allEventKinds
  , eventRegistry
  , legacyEventName
    -- * Envelope
  , makeEnvelope
    -- * Reading
  , loadTranscript
  , listLocalSessions
  , listLocalSessionsIn
  , transcriptFile
  ) where

import Core.SessionSummary (SessionSummary(..), sessionSummaryOf)
import Core.Types (CLIError, SessionId, StreamChunk(..), ToolEvent, ToolName, Usage)
import Config.Settings (getConfigDir)
import Data.Aeson (Value(..), object, toJSON, (.=))
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Lazy as BSL
import qualified Data.ByteString.Lazy.Char8 as BLC
import Data.Char (isAlphaNum)
import Data.List (sortOn)
import Data.Maybe (catMaybes)
import Data.Ord (Down(..))
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import System.Directory
    ( createDirectoryIfMissing
    , doesDirectoryExist
    , doesFileExist
    , getCurrentDirectory
    , listDirectory
    )
import System.FilePath ((</>))
import Core.Fs (chmodQuiet)

-- | Directory for one session: @~/.trha/sessions/<sid>@ (0700).
ensureSessionDir :: SessionId -> IO FilePath
ensureSessionDir sid = do
  dir <- sessionsDir
  let sessionDir = dir </> sanitizeSessionId sid
  createDirectoryIfMissing True sessionDir
  chmodQuiet sessionDir 0o700
  return sessionDir

-- | Full path of the transcript file for a session (creating the session
-- directory when missing -- used by the append path).
transcriptFile :: SessionId -> IO FilePath
transcriptFile sid = do
  dir <- ensureSessionDir sid
  return $ dir </> "transcript.jsonl"

-- | Read-only transcript path (no directory creation side effects).
transcriptPathOnly :: SessionId -> IO FilePath
transcriptPathOnly sid = do
  dir <- sessionsDir
  return $ dir </> sanitizeSessionId sid </> "transcript.jsonl"

-- | Record that a session was created (with the model in use).
-- | Record the session header.  The working directory is stored with it: a
-- transcript is only meaningful in the project it was produced in, and
-- `/resume` must not offer another project's conversations.
recordSession :: SessionId -> Text -> IO ()
recordSession sid model = do
  cwd <- getCurrentDirectory
  appendEnvelope sid "session" [ "model" .= model, "cwd" .= cwd ]

-- | Record a user message.
recordUser :: SessionId -> Text -> IO ()
recordUser sid text =
  appendEnvelope sid "user" [ "content" .= text ]

-- | Record the final (aggregated) assistant reply text.
recordAssistant :: SessionId -> Text -> IO ()
recordAssistant sid text =
  appendEnvelope sid "assistant" [ "content" .= text ]

-- | Record a tool invocation reported by the kernel.
recordTool :: SessionId -> ToolName -> [Text] -> IO ()
recordTool sid name args =
  appendEnvelope sid "tool" [ "tool" .= name, "args" .= args ]

-- | Record a full tool lifecycle event (Phase 2 S2).  Extends the legacy
-- tool line with @status@/@error@/@durationMs@; old readers keep working
-- because @tool@/@args@ are still present.
recordToolEvent :: SessionId -> ToolEvent -> IO ()
recordToolEvent sid ev =
  case toJSON ev of
    Object inner -> appendEnvelope sid "tool" (KM.toList inner)
    _ -> return ()

-- | Record token usage reported by the kernel.
recordDone :: SessionId -> Usage -> IO ()
recordDone sid usage =
  appendEnvelope sid "done" [ "usage" .= usage ]

-- | Record an error observed by the CLI.
recordError :: SessionId -> Text -> IO ()
recordError sid err =
  appendEnvelope sid "error" [ "content" .= err ]

-- | Record that a model request was issued with the given model name.
-- Model-visible inputs are logged so a transcript can reconstruct what was
-- sent ("model-visible means logged").
recordModelRequest :: SessionId -> Text -> IO ()
recordModelRequest sid model =
  appendEnvelope sid "model-request" [ "model" .= model ]

-- | Record the outcome of one kernel response chunk.
recordChunk :: SessionId -> Either CLIError StreamChunk -> IO ()
recordChunk sid (Left err) = recordError sid (T.pack (show err))
recordChunk sid (Right chunk) =
  case chunk of
    ChunkDelta text    -> recordAssistant sid text
    ChunkToolCall n as -> recordTool sid n as
    ChunkDone usage    -> recordDone sid usage

-- | Load all transcript entries of a session, skipping unparseable lines.
loadTranscript :: SessionId -> IO [Value]
loadTranscript sid = do
  file <- transcriptPathOnly sid
  exists <- doesFileExist file
  if not exists
    then return []
    else do
      content <- BSL.readFile file
      return $ foldr step [] (BLC.lines content)
  where
    step line acc = case Aeson.decode line :: Maybe Value of
      Just v  -> v : acc
      Nothing -> acc

-- | List local session summaries (newest first), scanning
-- @~/.trha/sessions/*/transcript.jsonl@ read-only.
listLocalSessions :: IO [SessionSummary]
listLocalSessions = do
  dir <- sessionsDir
  exists <- doesDirectoryExist dir
  if not exists
    then return []
    else do
      names <- listDirectory dir
      summaries <- fmap catMaybes $ mapM (summarize dir) names
      return $ sortOn (Down . ssLastTs) summaries
  where
    summarize :: FilePath -> FilePath -> IO (Maybe SessionSummary)
    summarize dir name = do
      isDir <- doesDirectoryExist (dir </> name)
      if not isDir
        then return Nothing
        else do
          events <- loadTranscript name
          if null events
            then return Nothing
            else return $ Just (sessionSummaryOf name events)

-- | Local sessions started in @dir@ only.
--
-- A transcript belongs to the project it was produced in: offering another
-- project's conversations in @/resume@ is how you end up resuming the wrong
-- context — and, since a session carries its own workspace, the wrong files.
--
-- Transcripts written before the @cwd@ field existed have 'Nothing' and are
-- therefore not offered here; their ids still resume if typed explicitly.
listLocalSessionsIn :: FilePath -> IO [SessionSummary]
listLocalSessionsIn dir = do
  allSessions <- listLocalSessions
  let here = T.pack dir
  pure [ s | s <- allSessions, ssCwd s == Just here ]

--------------------------------------------------------------------------------
-- Internal
--------------------------------------------------------------------------------

-- | ~/.trha/sessions
sessionsDir :: IO FilePath
sessionsDir = (</> "sessions") <$> getConfigDir

-- | Append one event as a JSON line (atomicity not required: appends are
-- idempotent to read thanks to line-skipping).
appendEntry :: SessionId -> Value -> IO ()
appendEntry sid entry = do
  file <- transcriptFile sid
  BSL.appendFile file (Aeson.encode entry <> "\n")

-- | Build one versioned transcript envelope (persistence-catalog style):
-- the legacy flat fields (@ts@/@event@/payload...) stay at the top level so
-- older readers keep working, and @v@/@id@ are added for versioning and
-- idempotent replay.  Pure so it is unit-testable.
makeEnvelope :: Text -> Text -> Text -> [(K.Key, Value)] -> Value
makeEnvelope evType ts eid extra =
  object ([ "v" .= (1 :: Int), "id" .= eid, "ts" .= ts, "event" .= evType ]
           ++ extra)

-- | Every transcript event type, as a single source of truth
-- (persistence-catalog style type map; the writers and the tests reference
-- these names instead of string literals).
data EventKind
  = EvSession
  | EvUser
  | EvAssistant
  | EvTool
  | EvDone
  | EvError
  | EvModelRequest
  deriving (Show, Eq, Ord, Enum, Bounded)

-- | Canonical wire name of each kind.
eventKindName :: EventKind -> Text
eventKindName k = case k of
  EvSession   -> "session"
  EvUser      -> "user"
  EvAssistant -> "assistant"
  EvTool      -> "tool"
  EvDone      -> "done"
  EvError     -> "error"
  EvModelRequest -> "model-request"

-- | All kinds, in declaration order.
allEventKinds :: [EventKind]
allEventKinds = [minBound .. maxBound]

-- | Registry: (canonical name, description).  One row per kind; no two
-- kinds share a name.
eventRegistry :: [(Text, Text)]
eventRegistry =
  [ ("session",   "session created with the active model")
  , ("user",      "user message")
  , ("assistant", "assistant reply text")
  , ("tool",      "tool lifecycle event (running/succeeded/failed)")
  , ("done",      "token usage reported by the kernel")
  , ("error",     "error observed by the CLI")
  , ("model-request", "a model request was sent (model-visible input)")
  ]

-- | Migrate a legacy (pre-envelope) event name to its canonical form.
-- Today every legacy name already matches; kept as the extension point
-- for future renames.
legacyEventName :: Text -> Text
legacyEventName t = case t of
  "tool_call" -> "tool"   -- historical alias kept for safety
  _           -> t

-- | Timestamp once and append a versioned envelope (session id is included
-- automatically as before).
appendEnvelope :: SessionId -> Text -> [(K.Key, Value)] -> IO ()
appendEnvelope sid evType extra = do
  ts <- timestamp
  appendEntry sid
    (makeEnvelope evType ts ts
      ([ "session" .= T.pack sid ] ++ extra))

-- | Timestamp in UTC ISO-8601 (machine-readable; display layers convert).
timestamp :: IO Text
timestamp =
  T.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" <$> getCurrentTime

-- | Keep only filesystem-safe characters when deriving a directory name
-- from a kernel-provided session id.
sanitizeSessionId :: SessionId -> SessionId
sanitizeSessionId = map (\c -> if isAlphaNum c || c `elem` (".-_" :: String) then c else '_')

-- (envelope rebuild trigger)
