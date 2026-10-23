{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Core.Agent.Types
  ( Agent(..)
  , AgentState(..)
  , AgentId
  , StepId
  , ToolCallId
  , ErrorType(..)
  , ApprovalRequest(..)
  , PlanMode(..)
  , StepStatus(..)
  , PlanStep(..)
  , Plan(..)
  , Message(..)
  , Result(..)
  , AgentConfig(..)
  ) where

import Control.Concurrent.STM
import Data.Aeson
  ( FromJSON (..), ToJSON (..), Value (..), object, withObject, withText,
    (.:), (.:?), (.!=), (.=) )
import Data.Aeson.Types (Parser)
import Data.Text (Text)
import qualified Data.Text as T

-- | Unique identifier for an agent
type AgentId = String

-- | Unique identifier for a step
type StepId = String

-- | Unique identifier for a tool call
type ToolCallId = String

-- | Error types that can occur
data ErrorType
  = ToolError String
  | LLMError String
  | TimeoutError
  | InterruptedError
  deriving (Show, Eq)

-- | A message in the conversation
data Message = Message
  { messageRole    :: Text
  , messageContent :: Text
  } deriving (Show, Eq)

-- | Result of an agent run
data Result = Result
  { resultText   :: Text
  , resultTokens :: Int
  } deriving (Show, Eq)

-- | A command held at the approval gate.
--
-- The kernel does not execute the gated action — it only decides whether the
-- host may proceed. 'approvalPayload' keeps the original request, so a
-- decision works without the host re-sending it, and a restart can still
-- answer "what was pending?".
data ApprovalRequest = ApprovalRequest
  { approvalId      :: String
  , approvalAction  :: String   -- ^ kind of gated command ("step", "tool", …)
  , approvalSummary :: Text     -- ^ one line the host can show a user
  , approvalPayload :: Value
  } deriving (Show, Eq)

--------------------------------------------------------------------------------
-- 多步计划
--
-- 内核不产生计划、也不执行步骤 —— 宿主提交一份步骤清单，内核只负责「哪一步
-- 现在可以跑」与「跑到哪了」。计划是数据（存在会话里、随 checkpoint 落盘），
-- 权限是 FSM（Planning / ExecutingStep 两个相位）。
--------------------------------------------------------------------------------

-- | How a submitted plan is meant to be gated.
data PlanMode
  = Stepwise   -- ^ 每一步都要单独批准（当前唯一实现的模式）
  | Auto       -- ^ 逐步放行、不逐条批准（尚未实现）
  deriving (Show, Eq)

-- | Per-step lifecycle.
--
-- @Approved@ 与 @Done@ 是两件事：前者是内核放行，后者是宿主回报「跑完了」。
-- 内核拿不到执行结果就不能自己猜，否则进度会说谎。
data StepStatus
  = StepPending
  | StepApproved
  | StepSkipped
  | StepRejected
  | StepDone
  | StepFailed
  deriving (Show, Eq)

data PlanStep = PlanStep
  { planStepId     :: String
  , planStepTitle  :: Text
  , planStepAction :: Value    -- ^ 宿主自己解释（命令/工具参数/纯描述）
  , planStepStatus :: StepStatus
  } deriving (Show, Eq)

data Plan = Plan
  { planId    :: String
  , planMode  :: PlanMode
  , planSteps :: [PlanStep]
  } deriving (Show, Eq)

-- | States of an agent
data AgentState
  = Idle
  | Processing StepId
  | WaitingForTool ToolCallId
  | AwaitingApproval ApprovalRequest
  | Planning                 -- ^ 计划进行中，下一步待决策（屏障）
  | ExecutingStep StepId     -- ^ 某步已放行，等宿主回报（屏障）
  | Completed Result
  | Error ErrorType
  deriving (Show, Eq)

-- | Agent configuration
data AgentConfig = AgentConfig
  { configModel    :: Text
  , configMaxSteps :: Int
  , configTimeout  :: Int
  } deriving (Show, Eq)

-- | An agent with its state and inbox
data Agent = Agent
  { agentId     :: AgentId
  , agentState  :: TVar AgentState
  , agentInbox  :: TQueue Message
  , agentConfig :: AgentConfig
  }

--------------------------------------------------------------------------------
-- JSON instances for the persistable subset.
--
-- Only what survives a kernel restart is encoded: the FSM state (and the
-- values it can carry). Dynamic projections and events stay in memory — they
-- are derived state and are recomputed on the next step.
--------------------------------------------------------------------------------

instance ToJSON ErrorType where
  toJSON (ToolError m)    = object ["kind" .= ("tool"    :: Text), "message" .= m]
  toJSON (LLMError m)     = object ["kind" .= ("llm"     :: Text), "message" .= m]
  toJSON TimeoutError     = object ["kind" .= ("timeout" :: Text)]
  toJSON InterruptedError = object ["kind" .= ("interrupted" :: Text)]

instance FromJSON ErrorType where
  parseJSON = withObject "ErrorType" $ \o -> do
    kind <- o .: "kind" :: Parser Text
    case kind of
      "tool"        -> ToolError <$> o .: "message"
      "llm"         -> LLMError <$> o .: "message"
      "timeout"     -> pure TimeoutError
      "interrupted" -> pure InterruptedError
      other         -> fail ("unknown error kind: " <> T.unpack other)

instance ToJSON Result where
  toJSON r = object ["text" .= resultText r, "tokens" .= resultTokens r]

instance FromJSON Result where
  parseJSON = withObject "Result" $ \o ->
    Result <$> o .: "text" <*> o .: "tokens"

instance ToJSON ApprovalRequest where
  toJSON r = object
    [ "id"      .= approvalId r
    , "action"  .= approvalAction r
    , "summary" .= approvalSummary r
    , "payload" .= approvalPayload r
    ]

instance FromJSON ApprovalRequest where
  parseJSON = withObject "ApprovalRequest" $ \o ->
    ApprovalRequest
      <$> o .: "id"
      <*> o .: "action"
      <*> o .: "summary"
      <*> o .: "payload"

instance ToJSON PlanMode where
  toJSON Stepwise = "stepwise"
  toJSON Auto     = "auto"

instance FromJSON PlanMode where
  parseJSON = withText "PlanMode" $ \case
    "stepwise" -> pure Stepwise
    "auto"     -> pure Auto
    other      -> fail ("unknown plan mode: " <> T.unpack other)

instance ToJSON StepStatus where
  toJSON StepPending  = "pending"
  toJSON StepApproved = "approved"
  toJSON StepSkipped  = "skipped"
  toJSON StepRejected = "rejected"
  toJSON StepDone     = "done"
  toJSON StepFailed   = "failed"

instance FromJSON StepStatus where
  parseJSON = withText "StepStatus" $ \case
    "pending"  -> pure StepPending
    "approved" -> pure StepApproved
    "skipped"  -> pure StepSkipped
    "rejected" -> pure StepRejected
    "done"     -> pure StepDone
    "failed"   -> pure StepFailed
    other      -> fail ("unknown step status: " <> T.unpack other)

instance ToJSON PlanStep where
  toJSON st = object
    [ "id"     .= planStepId st
    , "title"  .= planStepTitle st
    , "action" .= planStepAction st
    , "status" .= planStepStatus st
    ]

instance FromJSON PlanStep where
  parseJSON = withObject "PlanStep" $ \o ->
    PlanStep <$> o .: "id" <*> o .: "title"
             <*> (o .:? "action" .!= Null) <*> o .: "status"

instance ToJSON Plan where
  toJSON p = object
    [ "id"    .= planId p
    , "mode"  .= planMode p
    , "steps" .= planSteps p
    ]

instance FromJSON Plan where
  parseJSON = withObject "Plan" $ \o ->
    Plan <$> o .: "id" <*> o .: "mode" <*> o .: "steps"

instance ToJSON AgentState where
  toJSON Idle = object ["state" .= ("idle" :: Text)]
  toJSON (Processing sid) = object ["state" .= ("processing" :: Text), "step" .= sid]
  toJSON (WaitingForTool cid) = object ["state" .= ("waiting_for_tool" :: Text), "call" .= cid]
  toJSON (AwaitingApproval req) = object
    ["state" .= ("awaiting_approval" :: Text), "approval" .= req]
  toJSON Planning = object ["state" .= ("planning" :: Text)]
  toJSON (ExecutingStep sid) = object ["state" .= ("executing_step" :: Text), "step" .= sid]
  toJSON (Completed r) = object ["state" .= ("completed" :: Text), "result" .= r]
  toJSON (Error e) = object ["state" .= ("error" :: Text), "error" .= e]

instance FromJSON AgentState where
  parseJSON = withObject "AgentState" $ \o -> do
    st <- o .: "state" :: Parser Text
    case st of
      "idle"              -> pure Idle
      "processing"        -> Processing <$> o .: "step"
      "waiting_for_tool"  -> WaitingForTool <$> o .: "call"
      "awaiting_approval" -> AwaitingApproval <$> o .: "approval"
      "planning"          -> pure Planning
      "executing_step"    -> ExecutingStep <$> o .: "step"
      "completed"         -> Completed <$> o .: "result"
      "error"             -> Error <$> o .: "error"
      other               -> fail ("unknown agent state: " <> T.unpack other)