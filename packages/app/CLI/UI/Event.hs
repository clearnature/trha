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
  , flushParts
    -- * Tool invocation record (moved with 'PendingMsg': it is part of it)
  , ToolInv(..)
    -- * Harness run state
  , RunState(..)
  , runState
  , runStateLabel
    -- * Async events pushed by background threads
  , AppEvent(..)
  ) where

import Core.Types
import Data.Text (Text)
import qualified Data.Text as T
import UI.Completion (Completion)
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
  , pmTools   :: [ToolInv]   -- ^ Tool invocations seen so far (newest first)
  , pmStart   :: Text        -- ^ Timestamp of the first delta
  } deriving (Show)

-- | Open a fresh accumulation block stamped with the given timestamp.
newPending :: Text -> PendingMsg
newPending start = PendingMsg "" [] start

-- | Fold one chunk into the open block.  @ChunkDone@ is deliberately not
-- handled here: flushing is an event-loop decision, not a state transform.
reduceChunk :: StreamChunk -> PendingMsg -> PendingMsg
reduceChunk (ChunkDelta text)    pm = pm { pmContent = pmContent pm <> text }
reduceChunk (ChunkToolCall n as) pm = pm { pmTools = ToolInv n as : pmTools pm }
reduceChunk _                    pm = pm

-- | Tear the open block down into its parts: tool invocations in
-- chronological order, and the accumulated text (stripped).
flushParts :: PendingMsg -> ([ToolInv], Text)
flushParts pm = (reverse (pmTools pm), T.strip (pmContent pm))

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
  | EvToggleToolFold Int -- ^ flip the fold state of tool message @id@
  | EvCtxSize Int        -- ^ context size of the active model (startup fetch)
  | EvTodos (Either CLIError [TodoItem]) -- ^ sidebar TODO refresh
  | EvSessionTitle (Maybe Text)          -- ^ sidebar title refresh
  | EvCompletionIndex [Completion]       -- ^ @\@@-file index (startup scan)
  | EvProviders (Either CLIError [ProviderInfo]) -- ^ provider registry (TUI switching)
  | EvFinalReply Text                    -- ^ authoritative reply from the step
  deriving (Show)
