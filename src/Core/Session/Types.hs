{-# LANGUAGE OverloadedStrings #-}

module Core.Session.Types
  ( Session(..)
  , SessionEvent(..)
  , SessionId
  , SessionSnapshot(..)
  ) where

import Data.IORef
import qualified Data.Map as Map
import Data.Dynamic
import Data.Aeson
  ( FromJSON (..), ToJSON (..), Value, object, withObject, (.:), (.:?), (.!=), (.=) )
import Data.Aeson.Types (Parser)
import Data.Text (Text)
import Core.Agent.Types (AgentState, ApprovalRequest, Plan)

-- | Unique identifier for a session
type SessionId = String

-- | Events that can occur in a session.
--
-- Payloads are 'Value' rather than 'Dynamic' so the log can be written to disk
-- and read back: a 'Dynamic' is erased and has no encoding. Structured JSON is
-- also what the SDK's event type already uses.
--
-- @AgentStateChanged@ is what makes the log replayable — it is appended by the
-- same call that advances the FSM, so the FSM state is a fold over the log.
data SessionEvent
  = UserMessage Text
  | AssistantMessage Text
  | ToolCall String Value
  | ToolResult String Value
  | SystemEvent String
  | AgentStateChanged AgentState
  | ApprovalRequested ApprovalRequest
  | ApprovalDecided Bool
  | PlanChanged Plan
  deriving (Show, Eq)

instance ToJSON SessionEvent where
  toJSON (UserMessage t)      = object ["kind" .= ("user_message" :: Text), "text" .= t]
  toJSON (AssistantMessage t) = object ["kind" .= ("assistant_message" :: Text), "text" .= t]
  toJSON (ToolCall n p)       = object ["kind" .= ("tool_call" :: Text), "tool" .= n, "payload" .= p]
  toJSON (ToolResult n p)     = object ["kind" .= ("tool_result" :: Text), "tool" .= n, "payload" .= p]
  toJSON (SystemEvent s)      = object ["kind" .= ("system" :: Text), "text" .= s]
  toJSON (AgentStateChanged st) = object ["kind" .= ("agent_state" :: Text), "agentState" .= st]
  toJSON (ApprovalRequested req) = object ["kind" .= ("approval_requested" :: Text), "request" .= req]
  toJSON (ApprovalDecided ok) = object ["kind" .= ("approval_decided" :: Text), "approve" .= ok]
  toJSON (PlanChanged p) = object ["kind" .= ("plan_changed" :: Text), "plan" .= p]

instance FromJSON SessionEvent where
  parseJSON = withObject "SessionEvent" $ \o -> do
    kind <- o .: "kind" :: Parser Text
    case kind of
      "user_message"      -> UserMessage <$> o .: "text"
      "assistant_message" -> AssistantMessage <$> o .: "text"
      "tool_call"         -> ToolCall <$> o .: "tool" <*> o .: "payload"
      "tool_result"       -> ToolResult <$> o .: "tool" <*> o .: "payload"
      "system"            -> SystemEvent <$> o .: "text"
      "agent_state"       -> AgentStateChanged <$> o .: "agentState"
      "approval_requested" -> ApprovalRequested <$> o .: "request"
      "approval_decided"   -> ApprovalDecided <$> o .: "approve"
      "plan_changed"       -> PlanChanged <$> o .: "plan"
      other               -> fail ("unknown session event kind: " <> show other)

-- | A session contains an event log and projections
--
-- D-3：内核的**推理过程**对会话可见，分两处承载 ——
--   · 'projections'：event-sourcing 式派生状态（推理内核的 T6State 等，经 Dynamic 装箱）；
--   · 'agentState'：内核 FSM 状态（Core.Agent 的 AgentState），随每步推进。
-- 两者互补：投影是"算出了什么"，FSM 是"走到哪一步"。
data Session = Session
  { sessionId   :: SessionId
  , eventLog    :: IORef [SessionEvent]
  , projections :: IORef (Map.Map String Dynamic)
  , agentState  :: IORef AgentState
  , sessionPlan :: IORef (Maybe Plan)   -- ^ 多步计划：数据在会话里，权限在 FSM
  }

-- | The checkpoint of a session: identity, FSM state, and how many events that
-- FSM state already accounts for.
--
-- The event log itself is stored beside the checkpoint (one JSON object per
-- line) rather than inside it, so appending an event does not rewrite the
-- whole history.
--
-- 'projections' stay out of both: they are @Dynamic@, opaque to Core by
-- design (Core must not depend on the CPU layer's concrete types), and they
-- are recomputed on the next step.
--
-- 'snapshotEventCount' is what makes a crash between the two writes (log
-- first, checkpoint second) recoverable: restore replays the tail of the log
-- that the checkpoint has not accounted for yet.
data SessionSnapshot = SessionSnapshot
  { snapshotId         :: SessionId
  , snapshotAgentState :: AgentState
  , snapshotPlan       :: Maybe Plan
  , snapshotEventCount :: Int
  } deriving (Show, Eq)

instance ToJSON SessionSnapshot where
  toJSON s = object
    [ "v"          .= (3 :: Int)
    , "sessionId"  .= snapshotId s
    , "agentState" .= snapshotAgentState s
    , "plan"       .= snapshotPlan s
    , "eventCount" .= snapshotEventCount s
    ]

instance FromJSON SessionSnapshot where
  parseJSON = withObject "SessionSnapshot" $ \o ->
    -- @eventCount@ and @plan@ are optional so v1/v2 checkpoints (written before
    -- the log and the plan were persisted) still load.
    SessionSnapshot
      <$> o .: "sessionId"
      <*> o .: "agentState"
      <*> o .:? "plan"
      <*> o .:? "eventCount" .!= 0
