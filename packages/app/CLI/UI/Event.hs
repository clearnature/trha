{-# LANGUAGE OverloadedStrings #-}

-- | Pure stream-reduction core for the TUI, split out of @UI.Brick@ so that
-- the streaming pipeline is unit-testable without brick.
--
-- A reply arrives as a sequence of chunks (one 'StreamChunk' per event):
-- @ChunkDelta@ appends text, @ChunkToolCall@ records a tool invocation,
-- @ChunkDone@ is the flush signal.  Chunks may arrive individually today
-- (synchronous endpoint, kernel aggregates) or incrementally later (standard
-- SSE stream) — the reducers treat both uniformly.
module UI.Event
  ( -- * Streaming accumulation state
    PendingMsg(..)
  , newPending
  , reduceChunk
  , appendReasoning
  , flushParts
  , flushThinking
    -- * Routes (Home / Session)
  , Route(..)
    -- * Shell mode
  , shellCommandOf
    -- * Tool invocation record (moved with 'PendingMsg': it is part of it)
  , ToolInv(..)
    -- * Harness run state
  , RunState(..)
  , runState
  , runStateLabel
    -- * Tool-card focus (M6-8)
  , nextCardFocus
    -- * Async events pushed by background threads
  , AppEvent(..)
  ) where

import Core.Types
import Core.SSE (SseNotice(..))
import Core.SessionSummary (SessionSummary)
import Data.List (elemIndex)
import Data.Text (Text)
import Data.Time.Clock (UTCTime)
import qualified Data.Text as T
import UI.Completion (Completion)
import UI.Skills (Skill)
import UI.I18n (Lang(..), tr)
import UI.StatusInfo (StatusRow(..))

-- | Tool invocation record.
data ToolInv = ToolInv
  { tiName :: ToolName
  , tiArgs :: [Text]
  } deriving (Show, Eq)

-- | Streaming accumulation state for one assistant reply.
data PendingMsg = PendingMsg
  { pmContent :: Text        -- ^ Accumulated delta text
  , pmThinking :: Text       -- ^ Accumulated reasoning/thinking text
  , pmTools   :: [ToolInv]   -- ^ Tool invocations seen so far (newest first)
  , pmStart   :: Text        -- ^ Timestamp of the first delta
  } deriving (Show)

-- | Open a fresh accumulation block stamped with the given timestamp.
newPending :: Text -> PendingMsg
newPending start = PendingMsg "" "" [] start

-- | Fold one chunk into the open block.  @ChunkDone@ is deliberately not
-- handled here: flushing is an event-loop decision, not a state transform.
reduceChunk :: StreamChunk -> PendingMsg -> PendingMsg
reduceChunk (ChunkDelta text)    pm = pm { pmContent = pmContent pm <> text }
reduceChunk (ChunkToolCall n as) pm = pm { pmTools = ToolInv n as : pmTools pm }
reduceChunk _                    pm = pm

-- | Append one reasoning (thinking) delta.
appendReasoning :: Text -> PendingMsg -> PendingMsg
appendReasoning text pm = pm { pmThinking = pmThinking pm <> text }

-- | Tear the open block down into its parts: tool invocations in
-- chronological order, and the accumulated text (stripped).
flushParts :: PendingMsg -> ([ToolInv], Text)
flushParts pm = (reverse (pmTools pm), T.strip (pmContent pm))

-- | Accumulated reasoning text (stripped), empty when the model sent none.
flushThinking :: PendingMsg -> Text
flushThinking = T.strip . pmThinking

-- | Harness run state: the boolean busy flag becomes a three-state ladder
-- here so M3's approval lock has a state to live in.
data RunState = RunIdle | RunRunning | RunAwaiting
  deriving (Show, Eq)

-- | From the busy flag and whether a step is currently out with the host.
runState :: Bool -> Bool -> RunState
runState busy stepOut
  | not busy  = RunIdle
  | stepOut   = RunAwaiting
  | otherwise = RunRunning

-- | Localised status label per state (status bar + spinner label).
runStateLabel :: Lang -> RunState -> Text
runStateLabel lang st = case st of
  RunIdle     -> tr lang "Ready"
  RunRunning  -> tr lang "Thinking..."
  RunAwaiting -> tr lang "Awaiting approval..."

-- | Async events pushed by background threads.
data AppEvent
  = EvResponse (Either CLIError StreamChunk)
  | EvSession (Either CLIError SessionId)
  | EvSessions (Either CLIError [SessionId])
  | EvModels (Either CLIError [ModelInfo])
  | EvDeleted SessionId
  | EvPlan (Either CLIError PlanSubmit)
  | EvVerdict (Either CLIError PlanVerdict)
  | EvPlanState (Either CLIError (PlanView, Maybe Text))
  | EvTool (Either CLIError ToolEvent)
  | EvStatusInfo [StatusRow]
  | EvMetrics [(Text, Text)]
  | EvGitStat Text                            -- ^ +N -M ?K for the status bar
  | EvToggleToolFold Int -- ^ flip the fold state of tool message @id@
  | EvCtxSize Int        -- ^ context size of the active model (startup fetch)
  | EvTodos (Either CLIError [TodoItem]) -- ^ sidebar TODO refresh
  | EvSessionTitle (Maybe Text)          -- ^ sidebar title refresh
  | EvCompletionIndex [Completion]       -- ^ @\@@-file index (startup scan)
  | EvProviders (Either CLIError [ProviderInfo]) -- ^ provider registry (TUI switching)
  | EvSkills [Skill]                     -- ^ discovered SKILL.md files
  | EvProviderSaved (Either CLIError [ProviderInfo]) -- ^ add/edit result
  | EvFinalReply Text                    -- ^ authoritative reply from the step
  | EvNotice SseNotice                   -- ^ reasoning / step / compaction event
  | EvMode (Either CLIError SessionMode) -- ^ permission posture after Shift+Tab / Ctrl+Y
  | EvToast Text                        -- ^ transient notice (auto-dismisses)
  | EvToastExpire UTCTime               -- ^ dismiss only if this toast is still current
  | EvRecent [SessionSummary]           -- ^ local sessions shown on the Home route
  | EvSidebarInfo (Maybe Text) [Text] [Text] -- ^ cwd, files, instruction files
  | EvSessionInfo (Either CLIError SessionInfo) -- ^ goal + team tasks
  | EvAgents (Either CLIError [AgentEntry])     -- ^ session tree (subagents)
  | EvServices [Text] [Text]                   -- ^ LSP lines, MCP lines
  | EvBalance (Either CLIError Balance)         -- ^ provider account balance
  | EvSandboxConfig (Either CLIError Bool)       -- ^ scheduler's effective sandbox switch
  deriving (Show)

-- | Which screen the TUI is showing.  Home is the launch screen (MiMo's
-- home route); submitting a message moves to the session view.
data Route = RouteHome | RouteSession
  deriving (Show, Eq)

-- | Move the tool-card focus.  @ids@ are the card message ids in display
-- order; @Nothing@ means "no focus yet", in which case the newest card wins.
-- Moving past either end clamps to that end, and the result is always one of
-- @ids@ (or Nothing when there are no cards).
nextCardFocus :: [Int] -> Maybe Int -> Int -> Maybe Int
nextCardFocus [] _ _ = Nothing
nextCardFocus ids Nothing _ = Just (last ids)
nextCardFocus ids (Just cur) delta =
  case elemIndex cur ids of
    Nothing -> Just (last ids)
    Just i  -> Just (ids !! max 0 (min (i + delta) (length ids - 1)))

-- | Shell mode (MiMo's @!@ prefix): a leading @!@ turns the input into a
-- local shell command instead of a model message.
shellCommandOf :: Text -> Maybe Text
shellCommandOf raw =
  case T.stripPrefix "!" (T.strip raw) of
    Just c | not (T.null (T.strip c)) -> Just (T.strip c)
    _ -> Nothing
