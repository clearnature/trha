{-# LANGUAGE OverloadedStrings #-}

module Core.Session.Types
  ( Session(..)
  , SessionEvent(..)
  , SessionId
  ) where

import Data.IORef
import qualified Data.Map as Map
import Data.Dynamic
import Data.Text (Text)
import Core.Agent.Types (AgentState)

-- | Unique identifier for a session
type SessionId = String

-- | Events that can occur in a session
data SessionEvent
  = UserMessage Text
  | AssistantMessage Text
  | ToolCall String Dynamic
  | ToolResult String Dynamic
  | SystemEvent String
  deriving (Show)

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
  }