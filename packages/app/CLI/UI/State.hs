{-# LANGUAGE OverloadedStrings #-}

-- | TUI state types, split out of "UI.Brick".
--
-- The 149-field 'AppState' plus the small payload types it references, and
-- the pure helpers that belong to them.  No rendering, no IO: 'initialState'
-- stays in "UI.Brick" because it wires a live bridge, channel and brick
-- editor together.
module UI.State
  ( AppState(..)
  , ChatMessage(..)
  , mkMsg
  , toolMsg
  , ResourceName(..)
  , ProviderWizard(..)
  , wizardPrompts
  , wizardValue
  , wizardSet
  , SettingsTab(..)
  , SettingsFocus(..)
  , SettingsPanel(..)
  , tabList
  , tabLabel
  ) where

import Brick.BChan (BChan)
import Brick.Widgets.Edit (Editor)
import Bridge.Scheduler (SchedulerBridge)
import Core.SessionSummary (SessionSummary)
import Core.Types
    ( AgentEntry, Balance, CLIConfig, PlanView, ProviderInfo, SessionId
    , SessionMode, TodoItem, Usage )
import qualified Data.Map as Map
import Data.Text (Text)
import Data.Time.Clock (UTCTime)
import Data.Time.LocalTime (TimeZone)
import UI.Completion (Completion, CompletionState)
import UI.CustomCommands (CustomCommand)
import UI.Dialog (Dialog, DialogStack, SandboxSettings)
import UI.Event (AppEvent, PendingMsg, Route)
import UI.Frecency (Frecency)
import UI.I18n (Lang(..), tr)
import UI.InputHistory (HistState)
import UI.Layout (SidebarState)
import UI.ModelPrefs (ModelPrefs)
import UI.Render.ToolCard (ToolCard, ToolFold)
import UI.Render.ToolSummary (toolHeadline)
import UI.Skills (Skill)
import UI.Stash (Stash)
import UI.StatusInfo (StatusRow)
import UI.Theme (Theme)

-- | Provider add/edit wizard: one field per step; the editor holds the
-- current value.  Editing starts from an existing provider, adding from a
-- blank one.
data ProviderWizard = ProviderWizard
  { pwStep    :: Int
  , pwName    :: Text
  , pwKind    :: Text
  , pwBaseUrl :: Text
  , pwModels  :: Text
  , pwDefault :: Text
  , pwKey     :: Text
  , pwEffort  :: Text      -- ^ reasoning effort (blank = auto)
  , pwVision  :: Text      -- ^ comma separated vision models
  , pwAuthHeader :: Text   -- ^ yes / no
  , pwNoProxy    :: Text   -- ^ yes / no
  , pwHeaders    :: Text   -- ^ extra HTTP headers (JSON object)
  , pwExtraBody  :: Text   -- ^ extra body fields (JSON object)
  , pwThinking   :: Text   -- ^ anthropic thinking mode
  , pwResponsesMode :: Text -- ^ responses: stateless | stateful
  , pwCtxWindow   :: Text   -- ^ context window override (tokens)
  } deriving (Show, Eq)

wizardPrompts :: [Text]
wizardPrompts =
  [ "Provider name"
  , "Kind (openai / anthropic / responses)"
  , "Base URL"
  , "Models (comma separated)"
  , "Default model"
  , "API key (blank = keep existing)"
  , "Reasoning effort (auto|minimal|low|medium|high)"
  , "Vision models (comma separated, optional)"
  , "Send auth header (yes/no)"
  , "Bypass proxy (yes/no)"
  , "Extra headers (JSON object, optional)"
  , "Extra body (JSON object, optional)"
  , "Thinking mode (anthropic only: adaptive, optional)"
  , "Responses mode (stateless|stateful, optional)"
  , "Context window (tokens, optional)" ]

wizardValue :: ProviderWizard -> Int -> Text
wizardValue w n = case n of
  0 -> pwName w
  1 -> pwKind w
  2 -> pwBaseUrl w
  3 -> pwModels w
  4 -> pwDefault w
  5 -> pwKey w
  6 -> pwEffort w
  7 -> pwVision w
  8 -> pwAuthHeader w
  9 -> pwNoProxy w
  10 -> pwHeaders w
  11 -> pwExtraBody w
  12 -> pwThinking w
  13 -> pwResponsesMode w
  _ -> pwCtxWindow w

wizardSet :: Int -> Text -> ProviderWizard -> ProviderWizard
wizardSet n v w = case n of
  0 -> w { pwName = v }
  1 -> w { pwKind = v }
  2 -> w { pwBaseUrl = v }
  3 -> w { pwModels = v }
  4 -> w { pwDefault = v }
  5 -> w { pwKey = v }
  6 -> w { pwEffort = v }
  7 -> w { pwVision = v }
  8 -> w { pwAuthHeader = v }
  9 -> w { pwNoProxy = v }
  10 -> w { pwHeaders = v }
  11 -> w { pwExtraBody = v }
  12 -> w { pwThinking = v }
  13 -> w { pwResponsesMode = v }
  _ -> w { pwCtxWindow = v }

-- | Application state
data AppState = AppState
  { appMessages  :: [ChatMessage]
  , appInput     :: Editor Text ResourceName
  , appSessionId :: Maybe SessionId
  , appModel     :: Text
  , appEffort    :: Text
  , appStatus    :: Text
  , appBusy      :: Bool          -- ^ True while awaiting a response
  , appPending   :: Maybe PendingMsg -- ^ Assistant reply being accumulated (streaming)
  , appLastUsage :: Maybe Int     -- ^ Token usage of the last completed reply
  , appHist      :: HistState     -- ^ Input history navigation (REPL-shared file)
  , appDialogs   :: DialogStack      -- ^ modal dialog stack (top owns keys)
  , appEscLast   :: Maybe UTCTime    -- ^ last escape press (double-esc window)
  , appQuitLast  :: Maybe UTCTime    -- ^ last Ctrl+C press (double-press quit window)
  , appBridge    :: SchedulerBridge
  , appChan      :: BChan AppEvent
  , appLang      :: Lang
  , appSettings  :: Maybe SettingsPanel -- ^ /settings overlay (navigation/edit)
  , appEffCfg    :: CLIConfig           -- ^ effective config snapshot for the panel
  , appSysRows   :: [StatusRow]         -- ^ cached /settings Status rows
  , appMetrics    :: [(Text, Text)]     -- ^ static metric values (workspace/git)
  , appGitStat    :: Text               -- ^ +N -M ?K for the second status line
  , appCostSum    :: Double             -- ^ session cost estimate (CNY)
  , appLastCost   :: Double             -- ^ cost of the last turn (CNY)
  , appSessTokens :: Int                -- ^ cumulative tokens this session
  , appNow        :: Maybe UTCTime      -- ^ clock for the peak/off-peak label
  , appTz         :: Maybe TimeZone     -- ^ local zone for the status-bar clock
  , appPlan       :: Maybe PlanView     -- ^ live multi-step plan (kernel-owned)
  , appFolds      :: Map.Map Int ToolFold -- ^ tool-card fold states, keyed by msgId
  -- | Running tool cards by call id, so the closing event can update the card
  -- the opening event created instead of appending a second one. Empty call id
  -- (older scheduler) never matches, which keeps the old append behaviour.
  , appRunningTools :: Map.Map Text Int
  , appSelStart   :: Maybe Int            -- ^ drag-selection anchor (message id)
  , appSelEnd     :: Maybe Int            -- ^ drag-selection cursor (message id)
  , appCardFocus  :: Maybe Int          -- ^ focused tool card (msgId); Nothing = none
  , appMode       :: Maybe SessionMode  -- ^ permission posture (Shift+Tab / Ctrl+Y)
  , appSandbox    :: SandboxSettings    -- ^ /sandbox panel state (TUI-local)
  , appCacheNow   :: Maybe (Int, Int)   -- ^ last turn's (cache hit, miss)
  , appCacheSum   :: (Int, Int)         -- ^ session-total (cache hit, miss)
  , appCacheTurns :: Int                -- ^ turns that reported cache numbers
  , appCtxUsed    :: Maybe Int          -- ^ last prompt tokens (context used)
  , appToast      :: Maybe (Text, UTCTime) -- ^ transient notice + its stamp
  , appRoute      :: Route              -- ^ Home (launch) or Session view
  , appRecent     :: [SessionSummary]   -- ^ local sessions shown on Home
  , appStash      :: Stash              -- ^ parked drafts (M7-4)
  , appCwd        :: Maybe Text         -- ^ working directory shown on the sidebar
  , appFiles      :: [Text]             -- ^ a few workspace files (from the @ index)
  , appGoal       :: Maybe Text         -- ^ session goal objective
  , appInstructions :: [Text]           -- ^ AGENTS.md / REASONIX.md detected
  , appFrecency   :: Frecency           -- ^ command-panel usage counts
  , appModelPrefs :: ModelPrefs         -- ^ model favourites/recents
  , appTheme      :: Theme              -- ^ active palette (switchable at runtime)
  , appAgents     :: [AgentEntry]       -- ^ session tree for the sidebar
  , appVerbose    :: Bool               -- ^ expand every tool card
  , appLsp        :: [Text]             -- ^ LSP status lines
  , appMcp        :: [Text]             -- ^ MCP status lines
  , appBalance    :: Maybe Balance      -- ^ provider account balance
  , appTurnStart  :: Maybe UTCTime      -- ^ when the current turn started
  , appLastTps    :: Maybe Double       -- ^ completion tokens/s of the last turn
  , appLastDecodeTps :: Maybe Double    -- ^ same, but measured from the first token
  , appFirstToken :: Maybe UTCTime      -- ^ when this turn's first delta arrived
  , appApproval   :: Maybe Text         -- ^ parked tool-approval message (M3)
  , appAskTool    :: Maybe (String, [Text])  -- ^ tool identity captured from the ask event
  , appPendingDelete :: Maybe String        -- ^ session id awaiting delete confirmation
  , appPendingStop   :: Bool                -- ^ Ctrl+Alt+Q confirmation is open (service stop)
  , appUsage      :: Maybe Usage        -- ^ real usage echo of the last turn
  , appCtxSize    :: Maybe Int          -- ^ context size of the active model
  , appSidebar    :: SidebarState       -- ^ sidebar open/closed/auto (M4-1)
  , appTodos      :: [TodoItem]         -- ^ team tasks shown in the sidebar
  , appSessionTitle :: Maybe Text       -- ^ local transcript title of the session
  , appIndex      :: [Completion]       -- ^ @\@@-file index (M4-2)
  , appComp       :: Maybe CompletionState -- ^ open completion popup
  , appPalette    :: Maybe Dialog       -- ^ inline slash-command palette (DialogCommands)
  , appLeader     :: Bool               -- ^ leader key armed (M4-3)
  , appProvider   :: Maybe Text         -- ^ selected provider (Nothing = kernel inUse)
  , appProviders  :: [ProviderInfo]     -- ^ provider registry from the kernel
  , appSkills     :: [Skill]            -- ^ discovered SKILL.md files (.agents/.trha)
  , appCustomCmds :: [CustomCommand]    -- ^ user commands (~/.trha/commands)
  , appWizard     :: Maybe ProviderWizard -- ^ provider add/edit in progress
  }

-- | Chat message with timestamp
data ChatMessage = ChatMessage
  { msgRole    :: Text
  , msgContent :: Text
  , msgTime    :: Text
  , msgTool    :: Maybe ToolCard -- ^ structured tool-card payload
  , msgMeta    :: Maybe Text     -- ^ per-turn footer (model / token usage)
  , msgId      :: Int            -- ^ position-based id (stable: append-only)
  } deriving (Show)

-- | Plain message (no tool payload, no footer).
mkMsg :: Text -> Text -> Text -> ChatMessage
mkMsg role content t = ChatMessage role content t Nothing Nothing 0

-- | Tool-card message (content holds the collapsed headline for transcript
-- replay; the UI renders the foldable card from the payload).
toolMsg :: Text -> ToolCard -> Text -> ChatMessage
toolMsg role card t =
  ChatMessage role (toolHeadline card) t (Just card) Nothing 0

-- PendingMsg / ToolInv / AppEvent live in UI.Event (pure, unit-tested).

-- | Resource names
data ResourceName
  = MessageArea
  | InputArea
  -- | Per-message render cache key (message id, expanded?, focused?, selected?).
  | MsgCache Int Bool Bool Bool
  -- | The thinking block's ▸/▾ toggle (click target).
  | ThinkToggle Int
  deriving (Show, Eq, Ord)

data SettingsTab
  = TabSettings
  | TabStatus
  | TabStats
  deriving (Show, Eq, Enum, Bounded)

data SettingsFocus
  = FocusTabs
  | FocusSearch
  | FocusList
  deriving (Show, Eq)

-- | Panel state: active tab, focus region, list selection/query/edit.
data SettingsPanel = SettingsPanel
  { spTab   :: SettingsTab
  , spFocus :: SettingsFocus
  , spSel   :: Int            -- ^ selected index within the filtered rows
  , spQuery :: Text           -- ^ live filter (typed while the list is focused)
  , spEdit  :: Maybe Text     -- ^ Just buffer while editing a text value
  , spError :: Maybe Text     -- ^ last apply error (shown under the list)
  } deriving (Show)

tabList :: [SettingsTab]
tabList = [minBound .. maxBound]

tabLabel :: Lang -> SettingsTab -> Text
tabLabel lang t = tr lang (case t of
  TabSettings -> "Settings"
  TabStatus   -> "Status"
  TabStats    -> "Stats")
