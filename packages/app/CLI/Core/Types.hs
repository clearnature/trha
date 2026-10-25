{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}

module Core.Types
  ( -- * Core Types
    SessionId
  , AgentId
  , ToolName
  , Message(..)
  , SessionEvent(..)
  , AgentState(..)
  , Tool(..)
  , ModelInfo(..)
  , Usage(..)
  , StreamChunk(..)
  , PlanSubmit(..)
  , PlanVerdict(..)
  , PlanStepView(..)
  , PlanView(..)
  , planStepOut
  , splitPlanSteps
  , parsePlanView
  , renderPlanBrief
  , ToolRunStatus(..)
  , ToolEvent(..)
  , TodoStatus(..)
  , TodoItem(..)
  , PluginInfo(..)
  
    -- * Configuration
  , CLIConfig(..)
  , defaultCLIConfig
  
    -- * Errors
  , CLIError(..)
  ) where

import Data.Aeson
import Data.Aeson.Key (fromText)
import qualified Data.Aeson.KeyMap as KM
import Data.Aeson.Types (Parser, (.:), (.:?), (.!=), withObject)
import Data.Foldable (toList)
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import GHC.Generics (Generic)

-- | Unique identifier for a session
type SessionId = String

-- | Unique identifier for an agent
type AgentId = String

-- | Unique identifier for a tool
type ToolName = String

-- | A message in the conversation
data Message = Message
  { messageRole    :: Text
  , messageContent :: Text
  } deriving (Show, Eq, Generic)

instance ToJSON Message
instance FromJSON Message

-- | Events that can occur in a session
data SessionEvent
  = UserMessage Text
  | AssistantMessage Text
  | ToolCall ToolName Text
  | ToolResult ToolName Text
  | SystemEvent Text
  deriving (Show, Eq, Generic)

instance ToJSON SessionEvent
instance FromJSON SessionEvent

-- | States of an agent
data AgentState
  = Idle
  | Processing Text
  | WaitingForTool Text
  | Completed Text
  | Error Text
  deriving (Show, Eq, Generic)

instance ToJSON AgentState
instance FromJSON AgentState

-- | A tool with its metadata
data Tool = Tool
  { toolName        :: ToolName
  , toolDescription :: Text
  , toolSchema      :: Text
  } deriving (Show, Eq, Generic)

instance ToJSON Tool
instance FromJSON Tool

-- | Model information
data ModelInfo = ModelInfo
  { modelName        :: Text
  , modelDescription :: Text
  , modelContextSize :: Int
  } deriving (Show, Eq, Generic)

instance ToJSON ModelInfo
instance FromJSON ModelInfo

-- | A registered orchestration plugin (declarative view).
data PluginInfo = PluginInfo
  { pluginName        :: Text
  , pluginVersion     :: Text
  , pluginDescription :: Text
  } deriving (Show, Eq, Generic)

instance FromJSON PluginInfo where
  parseJSON = withObject "PluginInfo" $ \o -> PluginInfo
    <$> o .: "name"
    <*> o .: "version"
    <*> o .: "description"

-- | Usage statistics
data Usage = Usage
  { usagePromptTokens     :: Int
  , usageCompletionTokens :: Int
  , usageTotalTokens      :: Int
  } deriving (Show, Eq, Generic)

instance ToJSON Usage
instance FromJSON Usage

-- | Stream chunks from the LLM
data StreamChunk
  = ChunkDelta Text
  | ChunkToolCall ToolName [Text]
  | ChunkDone Usage
  deriving (Show, Eq, Generic)

instance ToJSON StreamChunk
instance FromJSON StreamChunk

-- | Outcome of submitting a plan through the approval gate: the
-- orchestration layer is waiting for a host decision.
data PlanSubmit
  = PlanAwaiting Text -- ^ pending plan request (held by the host)
  deriving (Show, Eq)

-- | Outcome of an approval decision on the single-command gate.
data PlanVerdict
  = PlanApproved Text -- ^ command released; reply text
  | PlanDenied
  deriving (Show, Eq)

-- | One step of a multi-step plan, as the kernel reports it.
data PlanStepView = PlanStepView
  { psvId     :: Text
  , psvTitle  :: Text
  , psvStatus :: Text   -- ^ pending | approved | skipped | rejected | done | failed
  } deriving (Show, Eq)

-- | Kernel-side plan state: the kernel owns it, the shell renders and drives it.
data PlanView = PlanView
  { pvId      :: Text
  , pvSteps   :: [PlanStepView]
  , pvPending :: Maybe Text  -- ^ step id awaiting a decision
  , pvPhase   :: Text        -- ^ planning | executing_step | idle
  } deriving (Show, Eq)

-- | The step currently out with the host, if any.
planStepOut :: PlanView -> Maybe PlanStepView
planStepOut pv
  | pvPhase pv /= "executing_step" = Nothing
  | otherwise = case [ s | s <- pvSteps pv, psvStatus s == "approved" ] of
      (s:_) -> Just s
      []    -> Nothing

-- | Split a typed plan into steps: one per line, or separated by @;@.
splitPlanSteps :: Text -> [Text]
splitPlanSteps raw =
  filter (not . T.null) . map T.strip $
    concatMap (T.splitOn ";") (T.lines raw)

-- | Parse the kernel's @{plan, pending, agentState}@ answer.
parsePlanView :: Value -> Maybe PlanView
parsePlanView (Object o) = do
  Object po <- field "plan" o
  Array steps <- field "steps" po
  let one (Object so) = do
        sid <- field "id" so >>= asText
        title <- field "title" so >>= asText
        status <- field "status" so >>= asText
        pure (PlanStepView sid title status)
      one _ = Nothing
      pending = case field "pending" o of
        Just (Object po') -> field "id" po' >>= asText
        _                 -> Nothing
      phase = case field "agentState" o of
        Just (Object so) -> fromMaybe "" (field "state" so >>= asText)
        _                -> ""
  pure PlanView
    { pvId = fromMaybe "" (field "id" po >>= asText)
    , pvSteps = mapMaybe one (toList steps)
    , pvPending = pending
    , pvPhase = phase
    }
parsePlanView _ = Nothing

-- | Field lookup by 'Text' (the aeson key type is not 'Text').
field :: Text -> Object -> Maybe Value
field k o = KM.lookup (fromText k) o

asText :: Value -> Maybe Text
asText (String t) = Just t
asText _          = Nothing

-- | Lifecycle status of a tool execution reported by the orchestration
-- layer over SSE (Phase 2 S2).
data ToolRunStatus
  = ToolRunRunning
  | ToolRunSucceeded
  | ToolRunFailed Text -- ^ failure detail (e.g. exit code)
  deriving (Show, Eq)

-- | One tool lifecycle event.
data ToolEvent = ToolEvent
  { teName       :: ToolName
  , teArgs       :: [Text]
  , teStatus     :: ToolRunStatus
  , teDurationMs :: Maybe Int
  , teOutput     :: Maybe Text -- ^ tail output preview (kernel, succeeded only)
  } deriving (Show, Eq)

instance FromJSON ToolRunStatus where
  parseJSON = withText "ToolRunStatus" $ \t ->
    case t of
      "running"   -> pure ToolRunRunning
      "succeeded" -> pure ToolRunSucceeded
      "failed"    -> pure (ToolRunFailed "")
      _           -> fail "unknown tool status"

instance ToJSON ToolRunStatus where
  toJSON ToolRunRunning   = String "running"
  toJSON ToolRunSucceeded = String "succeeded"
  toJSON (ToolRunFailed _) = String "failed"

instance FromJSON ToolEvent where
  parseJSON = withObject "ToolEvent" $ \o -> do
    name <- o .: "name"
    args <- o .:? "args" .!= ([] :: [Text])
    dur  <- o .:? "durationMs"
    st   <- o .: "status" :: Parser Text
    status <- case st of
      "running"   -> pure ToolRunRunning
      "succeeded" -> pure ToolRunSucceeded
      "failed"    -> ToolRunFailed <$> o .:? "error" .!= ""
      _           -> fail "unknown tool status"
    out <- o .:? "output"
    pure $ ToolEvent name args status dur out

-- | Status of one team task (the agent's TODO list).
data TodoStatus = TodoPending | TodoInProgress | TodoDone
  deriving (Show, Eq)

-- | One entry of the scheduler's @teamTasks@ array.
data TodoItem = TodoItem
  { todoId      :: Text
  , todoSubject :: Text
  , todoStatus  :: TodoStatus
  } deriving (Show, Eq)

instance FromJSON TodoStatus where
  parseJSON = withText "TodoStatus" $ \t -> case t of
    "pending"     -> pure TodoPending
    "in_progress" -> pure TodoInProgress
    "completed"   -> pure TodoDone
    _             -> fail "unknown todo status"

instance FromJSON TodoItem where
  parseJSON = withObject "TodoItem" $ \o ->
    TodoItem <$> o .: "id" <*> o .: "subject" <*> o .: "status"

instance ToJSON TodoStatus where
  toJSON TodoPending    = String "pending"
  toJSON TodoInProgress = String "in_progress"
  toJSON TodoDone       = String "completed"

instance ToJSON TodoItem where
  toJSON t = object
    [ "id" .= todoId t
    , "subject" .= todoSubject t
    , "status" .= todoStatus t
    ]

instance ToJSON ToolEvent where
  toJSON (ToolEvent name args st dur out) =
    object $
      [ "name" .= name
      , "args" .= args
      , "status" .= statusTag st
      , "durationMs" .= dur
      ]
      ++ [ "error" .= err | ToolRunFailed err <- [st], err /= "" ]
      ++ [ "output" .= o | Just o <- [out] ]
    where
      statusTag ToolRunRunning   = ("running" :: Text)
      statusTag ToolRunSucceeded = "succeeded"
      statusTag (ToolRunFailed _) = "failed"

-- | CLI configuration
data CLIConfig = CLIConfig
  { configHost       :: Text
  , configPort       :: Int
  , configModel      :: Text
  , configToken      :: Text
  , configMaxTokens  :: Int
  , configTimeout    :: Int
  , configRetries    :: Int
  , configVerbose    :: Bool
  , configTheme      :: Text
  , configLang       :: Text -- ^ "zh" (default) or "en" interface language
  , configMetrics    :: Text -- ^ status-line metric keys (comma separated)
  , configMarkdown   :: Bool -- ^ render assistant replies as markdown
  , configTimestamps :: Bool -- ^ show message timestamps
  , configHints      :: Bool -- ^ show the footer key hints
  , configBell       :: Bool -- ^ ring the terminal bell when a reply completes
  , configProxy      :: Text -- ^ "" (default: env proxy for remote, direct for loopback) | "none" | "http://host:port"
  } deriving (Show, Eq, Generic)

instance ToJSON CLIConfig

-- | Manual 'FromJSON' so that newer optional fields (token, theme) default
-- when reading settings files written by older versions.
instance FromJSON CLIConfig where
  parseJSON = withObject "CLIConfig" $ \v -> CLIConfig
    <$> v .: "configHost"
    <*> v .: "configPort"
    <*> v .: "configModel"
    <*> v .:? "configToken" .!= "dev-token"
    <*> v .: "configMaxTokens"
    <*> v .: "configTimeout"
    <*> v .: "configRetries"
    <*> v .: "configVerbose"
    <*> v .:? "configTheme" .!= "tokyo-night"
    <*> v .:? "configLang" .!= "zh"
    <*> v .:? "configMetrics" .!= "model,git,context,session"
    <*> v .:? "configMarkdown" .!= True
    <*> v .:? "configTimestamps" .!= True
    <*> v .:? "configHints" .!= True
    <*> v .:? "configBell" .!= False
    <*> v .:? "configProxy" .!= ""

-- | Default CLI configuration
defaultCLIConfig :: CLIConfig
defaultCLIConfig = CLIConfig
  { configHost      = "localhost"
  , configPort      = 3456
  , configModel     = "deepseek-chat"
  , configToken     = "dev-token"
  , configMaxTokens = 4096
  , configTimeout   = 120000
  , configRetries   = 3
  , configVerbose   = False
  , configTheme     = "tokyo-night"
  , configLang      = "zh"
  , configMetrics   = "model,git,context,session"
  , configMarkdown  = True
  , configTimestamps = True
  , configHints     = True
  , configBell      = False
  , configProxy     = ""
  }

-- | CLI errors
data CLIError
  = ConnectionError Text
  | AuthenticationError Text
  | ValidationError Text
  | ServerError Text
  | TimeoutError
  | ModelError Text
  | UnknownCLIError Text
  deriving (Show, Eq, Generic)

instance ToJSON CLIError
instance FromJSON CLIError

-- | Compact plan rendering for the plain REPL (the TUI draws a card instead).
renderPlanBrief :: PlanView -> Text
renderPlanBrief pv = T.unlines $
  [ "Plan " <> pvId pv <> " (" <> pvPhase pv <> ")" ]
    ++ [ "  " <> T.pack (show n) <> ". [" <> mark (psvStatus st) <> "] "
           <> psvTitle st
           <> (if pvPending pv == Just (psvId st) then "  <- pending" else "")
       | (n, st) <- zip [1 :: Int ..] (pvSteps pv) ]
  where
    mark "done"     = "x"
    mark "failed"   = "!"
    mark "skipped"  = "-"
    mark "approved" = "+"
    mark "rejected" = "r"
    mark _          = "."
