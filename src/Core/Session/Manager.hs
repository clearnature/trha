module Core.Session.Manager
  ( createSession
  , appendEvent
  , getEvents
  , setProjection
  , getProjection
  , projectionNames
  , getAgentState
  , setAgentState
  , advanceAgent
  , pendingApproval
  , requestApproval
  , decideApproval
  , getPlan
  , submitPlan
  , planMove
  , PlanMove(..)
  , snapshotSession
  , restoreSession
  ) where

import Core.Session.Types
import Core.Agent.Types
  ( AgentState (..), ApprovalRequest (..), Plan (..), PlanMode (..), PlanStep (..) )
import Core.Agent.StateMachine
  ( AgentCommand (..), markApproved, markRejected, markReported, markSkipped
  , pendingStep, planFinished, transition )
import Data.IORef
import Data.Dynamic (Dynamic)
import Data.List (foldl')
import qualified Data.Map as Map

-- | Create a new session with a given ID
createSession :: SessionId -> IO Session
createSession sid = do
  logRef <- newIORef []
  projRef <- newIORef Map.empty
  stRef <- newIORef Idle          -- D-3：新会话的内核 FSM 从 Idle 开始
  planRef <- newIORef Nothing
  return $ Session sid logRef projRef stRef planRef

-- | Append an event to the session log.
--
-- Strict on purpose: the log is the persistence payload, so a thunk chain
-- would only be forced (and then serialized) later.
appendEvent :: Session -> SessionEvent -> IO ()
appendEvent session event =
  modifyIORef' (eventLog session) (++ [event])

-- | Get all events from the session log, oldest first
getEvents :: Session -> IO [SessionEvent]
getEvents session = readIORef (eventLog session)

--------------------------------------------------------------------------------
-- 投影（projections）
--
-- 投影是"由事件日志重放得出的派生状态"。内核的**推理状态**（CPU 层的 T6State）
-- 与**内核 FSM 状态**（Core.Agent.AgentState）都经这里上浮到会话，使"推理过程"
-- 对内核可见。
--
-- ⚠️ 分层：本模块只碰 `Dynamic`，**不知道** T6State/AgentState 这些具体类型 ——
-- 装箱（toDyn）由调用方（API.Server，本就同时依赖两层）完成。
-- 因此 Core 不会反向依赖 Infrastructure。
--------------------------------------------------------------------------------

-- | 写入一个投影（按名字覆盖写）。用严格的 @modifyIORef'@，避免 thunk 累积。
setProjection :: Session -> String -> Dynamic -> IO ()
setProjection session name val =
  modifyIORef' (projections session) (Map.insert name val)

-- | 读取一个投影；不存在返回 'Nothing'。
getProjection :: Session -> String -> IO (Maybe Dynamic)
getProjection session name = Map.lookup name <$> readIORef (projections session)

-- | 当前已写入的投影名（便于测试与诊断）。
projectionNames :: Session -> IO [String]
projectionNames session = Map.keys <$> readIORef (projections session)

--------------------------------------------------------------------------------
-- 内核 FSM 状态（D-3）
--
-- Core.Agent.StateMachine 的状态机此前只有测试覆盖、无生产调用点（§5「B 档」）。
-- 这里把它接到会话上：每个会话持有一个 AgentState，随每步经 'transition' 推进，
-- 于是"推理走到哪一步"对内核可见。
--------------------------------------------------------------------------------

-- | 读取会话的内核 FSM 状态。
getAgentState :: Session -> IO AgentState
getAgentState = readIORef . agentState

-- | 直接设置内核 FSM 状态（供测试/恢复用）。
setAgentState :: Session -> AgentState -> IO ()
setAgentState session st = writeIORef (agentState session) st

-- | 按一条命令推进内核 FSM，返回推进后的状态。
--   用 'transition' 而非自造规则 —— 保持与 Core.Agent.StateMachine 的语义单一来源。
advanceAgent :: Session -> AgentCommand -> IO AgentState
advanceAgent session cmd = do
  cur <- getAgentState session
  let nxt = transition cur cmd
  setAgentState session nxt
  pure nxt

--------------------------------------------------------------------------------
-- 审批闸门（命令屏障）
--
-- 「命令」（一次要执行的步/工具）在放行前停在 AwaitingApproval。闸门只决定
-- 能不能过，不执行被批准的动作 —— 执行归宿主。
--------------------------------------------------------------------------------

-- | The request currently parked at the gate, if any.
pendingApproval :: Session -> IO (Maybe ApprovalRequest)
pendingApproval session = do
  st <- readIORef (agentState session)
  pure $ case st of
    AwaitingApproval req -> Just req
    _                    -> Nothing

-- | Park a command at the gate. Returns the request that now holds the session,
-- or 'Nothing' when the current state cannot hold one (already parked, or
-- completed) — the FSM, not this function, decides what is legal.
requestApproval :: Session -> ApprovalRequest -> IO (Maybe ApprovalRequest)
requestApproval session req = do
  st <- readIORef (agentState session)
  let nxt = transition st (RequestApprovalCommand req)
  case nxt of
    -- Same request id means the FSM kept the existing park (only the FSM
    -- decides legality); report "nothing new" so callers do not log a second
    -- request that never took effect.
    AwaitingApproval r | approvalId r == approvalId req ->
      writeIORef (agentState session) nxt >> pure (Just r)
    _ -> pure Nothing

-- | Resolve the parked request.
--
-- 'atomicModifyIORef'' makes the check-and-decide one step: two decisions
-- racing (a double click, two hosts) cannot both win — the loser sees 'Nothing'
-- because the state already left 'AwaitingApproval'.
decideApproval :: Session -> Bool -> IO (Maybe AgentState)
decideApproval session approve = atomicModifyIORef' (agentState session) $ \cur ->
  case cur of
    AwaitingApproval _ ->
      let nxt = transition cur (if approve then ApproveCommand else RejectCommand)
      in (nxt, Just nxt)
    _ -> (cur, Nothing)

--------------------------------------------------------------------------------
-- 多步计划
--
-- 计划是数据，权限是 FSM：'planMove' 在同一个地方校验相位、改计划、推进 FSM，
-- 使「第几条步骤现在可以跑」只有一个答案。
--------------------------------------------------------------------------------

-- | The plan currently attached to the session, if any.
getPlan :: Session -> IO (Maybe Plan)
getPlan = readIORef . sessionPlan

-- | Attach a freshly submitted plan and enter the planning phase.
--
-- Refused unless the session is idle: a plan is a conversation-wide
-- commitment, so a second one while the first is live would make "which step is
-- pending" ambiguous.
submitPlan :: Session -> Plan -> IO (Maybe Plan)
submitPlan session plan = do
  st <- getAgentState session
  -- The phase check is explicit: 'transition' maps Planning→Planning for a new
  -- plan too (illegal commands are inert), so matching the result alone would
  -- let a second plan overwrite the first.
  case (st, transition st (SubmitPlanCommand (planMode plan))) of
    (Idle, Planning) -> do
      writeIORef (sessionPlan session) (Just plan)
      setAgentState session Planning
      pure (Just plan)
    _ -> pure Nothing

-- | One move of the plan.
data PlanMove
  = MoveApprove                -- ^ 放行当前待决步 → ExecutingStep
  | MoveSkip                   -- ^ 跳过当前待决步
  | MoveReject                 -- ^ 拒绝当前待决步 → 计划停住
  | MoveReport String Bool     -- ^ 宿主回报某步结果（ok?）
  | MoveAbandon                -- ^ 放弃整个计划
  deriving (Show, Eq)

-- | Apply a plan move.
--
-- Returns the resulting plan and FSM state, or 'Nothing' when the move is
-- illegal in the current phase (nothing planned, nothing pending, a different
-- step is out with the host, …). The phase check is what makes the gate real:
-- approving twice, or reporting an unreleased step, changes nothing.
planMove :: Session -> PlanMove -> IO (Maybe (Plan, AgentState))
planMove session move = do
  st <- getAgentState session
  mplan <- getPlan session
  case (st, mplan, move) of
    (Planning, Just plan, MoveApprove) ->
      case pendingStep plan of
        Nothing   -> pure Nothing
        Just step -> commit st (markApproved plan) (ApproveStepCommand (planStepId step))
    (Planning, Just plan, MoveSkip) ->
      case pendingStep plan of
        Nothing -> pure Nothing
        Just _  -> commit st (markSkipped plan) SkipStepCommand
    (Planning, Just plan, MoveReject) ->
      case pendingStep plan of
        Nothing -> pure Nothing
        Just _  -> commitHalt st (markRejected plan) RejectStepCommand
    (ExecutingStep sid, Just plan, MoveReport rid ok)
      | rid == sid -> commit st (markReported rid ok plan) (ReportStepCommand rid ok)
    (_, Just plan, MoveAbandon)
      | st == Planning || isExecuting st -> commitHalt st plan AbandonPlanCommand
    _ -> pure Nothing
  where
    isExecuting s = case s of
      ExecutingStep _ -> True
      _               -> False

    -- 改计划 + 推 FSM；计划已无待决步时收尾（FinishPlanCommand）。
    commit st plan' cmd = do
      let st' = transition st cmd
          st'' = if planFinished plan' then transition st' FinishPlanCommand else st'
      writeIORef (sessionPlan session) (Just plan')
      writeIORef (agentState session) st''
      pure $ Just (plan', st'')

    -- 拒绝/放弃：计划停住，剩余的 pending 步骤原样保留作记录。
    commitHalt st plan' cmd = do
      let st' = transition st cmd
      writeIORef (sessionPlan session) (Just plan')
      writeIORef (agentState session) st'
      pure $ Just (plan', st')

-- | Capture the persistable slice: identity, FSM state, and how many events
-- that state already accounts for.
snapshotSession :: Session -> IO SessionSnapshot
snapshotSession session = do
  st <- getAgentState session
  evs <- getEvents session
  plan <- getPlan session
  pure $ SessionSnapshot (sessionId session) st plan (length evs)

-- | Rebuild a session from its checkpoint plus the persisted event log.
--
-- The checkpoint is written *after* the log, so a crash between the two writes
-- leaves the log ahead of it. The tail beyond 'snapshotEventCount' is therefore
-- replayed; anything the checkpoint already covers is not (the checkpoint is
-- the cheaper, authoritative summary of it).
--
-- If the log is shorter than the checkpoint claims (truncated file, state
-- restored from an older copy), nothing is replayed and the checkpoint's state
-- stands — better than resurrecting a state the checkpoint moved past.
--
-- Projections start empty by design: they are derived state.
restoreSession :: SessionSnapshot -> [SessionEvent] -> IO Session
restoreSession snap events = do
  session <- createSession (snapshotId snap)
  let tailEvents = drop (snapshotEventCount snap) events
      st'  = foldl' applyState (snapshotAgentState snap) tailEvents
      plan = foldl' applyPlan (snapshotPlan snap) tailEvents
  setAgentState session st'
  writeIORef (sessionPlan session) plan
  writeIORef (eventLog session) events
  pure session
  where
    applyState _ (AgentStateChanged st) = st
    applyState st _                     = st
    applyPlan _ (PlanChanged p) = Just p
    applyPlan p _               = p
