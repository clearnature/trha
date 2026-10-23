module Core.Agent.StateMachine
  ( createAgent
  , updateState
  , getState
  , transition
  , AgentCommand (..)   -- D-3：会话层要用它推进 FSM（此前未导出）
  ) where

import Core.Agent.Types
import Control.Concurrent.STM

-- | Create a new agent
createAgent :: AgentId -> AgentConfig -> IO Agent
createAgent aid config = do
  stateVar <- newTVarIO Idle
  inboxQueue <- newTQueueIO
  return $ Agent aid stateVar inboxQueue config

-- | Update the agent's state
updateState :: Agent -> AgentState -> IO ()
updateState agent newState = do
  atomically $ writeTVar (agentState agent) newState

-- | Get the agent's current state
getState :: Agent -> IO AgentState
getState agent = do
  readTVarIO (agentState agent)

-- | State transition logic
--
-- The approval cases make the gate a real barrier rather than a flag:
--
--   * @RequestApprovalCommand@ parks the session, from 'Idle' or from a running
--     step (a tool call asking permission happens mid-step);
--   * @ApproveCommand@ / @RejectCommand@ are only accepted while parked, and
--     both release to 'Idle'. Approval releases the command, it does not run
--     it — the kernel has no tool executor, and the host owns execution, so
--     the host re-issues the step it was about to run;
--   * everything else while parked falls through to "stay": that is the
--     barrier, so a step cannot slip past a pending decision.
--
-- Rejection is deliberately not an 'Error': refusing a command is a decision,
-- not a fault of the session.
transition :: AgentState -> AgentCommand -> AgentState
transition Idle (StartCommand _) = Processing "step-1"
transition (Processing _) (ToolCallCommand _ _) = WaitingForTool "call-1"
transition (WaitingForTool _) (ToolResultCommand _) = Processing "step-2"
transition (Processing _) (CompleteCommand result) = Completed result
transition (Processing _) (RequestApprovalCommand req) = AwaitingApproval req
transition Idle (RequestApprovalCommand req) = AwaitingApproval req
transition (AwaitingApproval _) ApproveCommand = Idle
transition (AwaitingApproval _) RejectCommand = Idle
transition _ (ErrorCommand err) = Error err
transition state _ = state  -- Invalid transition (or barrier), stay put

-- | Agent commands for state transitions
data AgentCommand
  = StartCommand StepId
  | ToolCallCommand ToolCallId String
  | ToolResultCommand String
  | CompleteCommand Result
  | ErrorCommand ErrorType
  | RequestApprovalCommand ApprovalRequest
  | ApproveCommand
  | RejectCommand
  deriving (Show, Eq)