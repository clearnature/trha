{-# LANGUAGE OverloadedStrings #-}

module Core.Handlers
  ( -- * Handlers
    listSessionsHandler
  , createSessionHandler
  , getSessionHandler
  , deleteSessionHandler
  , getMessagesHandler
  , sendMessageHandler
  , getAgentStateHandler
  , updateAgentStateHandler
  , listToolsHandler
  , registerToolHandler
  , unregisterToolHandler
  , listModelsHandler
  , getModelHandler
  , healthCheckHandler
  ) where

import Core.Types
import Servant
import Data.IORef
import qualified Data.Map as Map
import Data.Text (Text)

-- | In-memory storage (placeholder)
type SessionStore = IORef (Map.Map String [SessionEvent])
type AgentStore = IORef (Map.Map String AgentState)
type ToolStore = IORef (Map.Map String Tool)
type ModelStore = IORef (Map.Map String ModelInfo)

-- | Create stores
createStores :: IO (SessionStore, AgentStore, ToolStore, ModelStore)
createStores = do
  sessions <- newIORef Map.empty
  agents <- newIORef Map.empty
  tools <- newIORef Map.empty
  models <- newIORef Map.empty
  return (sessions, agents, tools, models)

-- | List sessions handler
listSessionsHandler :: Handler [SessionId]
listSessionsHandler = do
  -- Placeholder: return empty list
  return []

-- | Create session handler
createSessionHandler :: () -> Handler SessionId
createSessionHandler _ = do
  -- Placeholder: generate session ID
  return "session-1"

-- | Get session handler
getSessionHandler :: SessionId -> Handler SessionEvent
getSessionHandler sessionId = do
  -- Placeholder: return dummy event
  return $ UserMessage "Hello"

-- | Delete session handler
deleteSessionHandler :: SessionId -> Handler ()
deleteSessionHandler sessionId = do
  -- Placeholder: do nothing
  return ()

-- | Get messages handler
getMessagesHandler :: SessionId -> Handler [Message]
getMessagesHandler sessionId = do
  -- Placeholder: return empty list
  return []

-- | Send message handler
sendMessageHandler :: SessionId -> Message -> Handler StreamChunk
sendMessageHandler sessionId message = do
  -- Placeholder: return dummy response
  return $ ChunkDelta "Response from server"

-- | Get agent state handler
getAgentStateHandler :: AgentId -> Handler AgentState
getAgentStateHandler agentId = do
  -- Placeholder: return idle state
  return Idle

-- | Update agent state handler
updateAgentStateHandler :: AgentId -> AgentState -> Handler ()
updateAgentStateHandler agentId state = do
  -- Placeholder: do nothing
  return ()

-- | List tools handler
listToolsHandler :: Handler [Tool]
listToolsHandler = do
  -- Placeholder: return empty list
  return []

-- | Register tool handler
registerToolHandler :: Tool -> Handler ()
registerToolHandler tool = do
  -- Placeholder: do nothing
  return ()

-- | Unregister tool handler
unregisterToolHandler :: ToolName -> Handler ()
unregisterToolHandler toolName = do
  -- Placeholder: do nothing
  return ()

-- | List models handler
listModelsHandler :: Handler [ModelInfo]
listModelsHandler = do
  -- Placeholder: return dummy model
  return [ModelInfo "deepseek-chat" "DeepSeek Chat Model" 4096]

-- | Get model handler
getModelHandler :: Text -> Handler ModelInfo
getModelHandler modelName = do
  -- Placeholder: return dummy model
  return $ ModelInfo modelName "Model description" 4096

-- | Health check handler
healthCheckHandler :: Handler Bool
healthCheckHandler = do
  -- Placeholder: return true
  return True