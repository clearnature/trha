module Core.Agent.StateMachine
  ( createAgent
  , updateState
  , getState
  , transition
  , AgentCommand (..)   -- D-3：会话层要用它推进 FSM（此前未导出）
    -- * 计划（多步）迁移
  , pendingStep
  , markApproved
  , markSkipped
  , markRejected
  , markReported
  , planFinished
  ) where

import Data.Maybe (isNothing)
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
-- 计划：提交后进入 Planning（下一步待决策）；批准某步则放行到 ExecutingStep，
-- 宿主回报后才回到 Planning 或收尾。Planning 与 ExecutingStep 期间其他命令
-- 全部落到「保持不变」—— 计划与对话步互斥，避免两条线索交错。
transition Idle (SubmitPlanCommand _) = Planning
transition Planning (ApproveStepCommand sid) = ExecutingStep sid
transition Planning SkipStepCommand = Planning
transition Planning RejectStepCommand = Idle
transition Planning FinishPlanCommand = Idle
transition (ExecutingStep _) (ReportStepCommand _ _) = Planning
transition Planning AbandonPlanCommand = Idle
transition (ExecutingStep _) AbandonPlanCommand = Idle
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
  | SubmitPlanCommand PlanMode
  | ApproveStepCommand StepId
  | SkipStepCommand
  | RejectStepCommand
  | ReportStepCommand StepId Bool
  | AbandonPlanCommand
  | FinishPlanCommand
  deriving (Show, Eq)

--------------------------------------------------------------------------------
-- 计划的纯迁移
--
-- 这些函数只改「计划这份数据」，合法性由 'transition' 把关。step 状态与 FSM
-- 相位是两件事：批准（Approved）结束于 FSM 的 ExecutingStep，回报（Done/Failed）
-- 才把它推回 Planning。
--------------------------------------------------------------------------------

-- | The next step that still needs a decision.
pendingStep :: Plan -> Maybe PlanStep
pendingStep plan = case [ st | st <- planSteps plan, planStepStatus st == StepPending ] of
  (st:_) -> Just st
  []     -> Nothing

setStatus :: String -> StepStatus -> Plan -> Plan
setStatus sid status plan = plan
  { planSteps = [ if planStepId st == sid then st { planStepStatus = status } else st
                | st <- planSteps plan ] }

-- | 放行当前待决步（调用方已确认它就是 pendingStep）。
markApproved :: Plan -> Plan
markApproved plan = case pendingStep plan of
  Nothing -> plan
  Just st -> setStatus (planStepId st) StepApproved plan

-- | 跳过当前待决步：不执行、也不算失败。
markSkipped :: Plan -> Plan
markSkipped plan = case pendingStep plan of
  Nothing -> plan
  Just st -> setStatus (planStepId st) StepSkipped plan

-- | 拒绝当前待决步：计划就此停住（后续步骤保持 pending，记录完整）。
markRejected :: Plan -> Plan
markRejected plan = case pendingStep plan of
  Nothing -> plan
  Just st -> setStatus (planStepId st) StepRejected plan

-- | 宿主回报某步的执行结果。
markReported :: String -> Bool -> Plan -> Plan
markReported sid ok = setStatus sid (if ok then StepDone else StepFailed)

-- | 计划是否可以收尾：既没有待决步，也没有「已放行但还没回报」的步。
--
-- 只看 pending 会把「刚批准最后一步」误判成结束 —— 那一步还在宿主手里跑，
-- 屏障必须留着。
planFinished :: Plan -> Bool
planFinished plan =
  isNothing (pendingStep plan)
    && not (any ((== StepApproved) . planStepStatus) (planSteps plan))