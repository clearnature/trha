module Orchestration.Subagent.Manager
  ( SubAgentManager(..)
  , createSubAgentManager
  , spawnSubAgent
  , terminateSubAgent
  , listSubAgents
  ) where

import Orchestration.Subagent.Types
import Data.IORef
import qualified Data.Map as Map

-- | Sub-agent manager
data SubAgentManager = SubAgentManager
  { agents :: IORef (Map.Map String SubAgent)
  }

-- | Create a new sub-agent manager
createSubAgentManager :: IO SubAgentManager
createSubAgentManager = do
  agentsRef <- newIORef Map.empty
  return $ SubAgentManager agentsRef

-- | Spawn a new sub-agent
spawnSubAgent :: SubAgentManager -> SubAgentConfig -> IO SubAgent
spawnSubAgent manager config = do
  agentsMap <- readIORef (agents manager)
  let agentId = "subagent-" ++ show (Map.size agentsMap)
  let agent = SubAgent agentId config SubAgentIdle
  modifyIORef (agents manager) (Map.insert agentId agent)
  return agent

-- | Terminate a sub-agent
terminateSubAgent :: SubAgentManager -> String -> IO ()
terminateSubAgent manager agentId = do
  modifyIORef (agents manager) (Map.delete agentId)

-- | List all sub-agents
listSubAgents :: SubAgentManager -> IO [SubAgent]
listSubAgents manager = do
  agentsMap <- readIORef (agents manager)
  return $ Map.elems agentsMap