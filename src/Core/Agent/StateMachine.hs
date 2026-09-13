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
transition :: AgentState -> AgentCommand -> AgentState
transition Idle (StartCommand _) = Processing "step-1"
transition (Processing _) (ToolCallCommand _ _) = WaitingForTool "call-1"
transition (WaitingForTool _) (ToolResultCommand _) = Processing "step-2"
transition (Processing _) (CompleteCommand result) = Completed result
transition _ (ErrorCommand err) = Error err
transition state _ = state  -- Invalid transition, stay in current state

-- | Agent commands for state transitions
data AgentCommand
  = StartCommand StepId
  | ToolCallCommand ToolCallId String
  | ToolResultCommand String
  | CompleteCommand Result
  | ErrorCommand ErrorType
  deriving (Show, Eq)