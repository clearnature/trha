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
  ) where

import Core.Session.Types
import Core.Agent.Types (AgentState (..))
import Core.Agent.StateMachine (AgentCommand (..), transition)
import Data.IORef
import Data.Dynamic (Dynamic)
import qualified Data.Map as Map

-- | Create a new session with a given ID
createSession :: SessionId -> IO Session
createSession sid = do
  logRef <- newIORef []
  projRef <- newIORef Map.empty
  stRef <- newIORef Idle          -- D-3：新会话的内核 FSM 从 Idle 开始
  return $ Session sid logRef projRef stRef

-- | Append an event to the session log
appendEvent :: Session -> SessionEvent -> IO ()
appendEvent session event = do
  modifyIORef (eventLog session) (++ [event])

-- | Get all events from the session
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
