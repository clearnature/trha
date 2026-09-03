{-# LANGUAGE OverloadedStrings #-}

module Core.Client
  ( -- * Client
    SDKClient(..)
  , createClient
  , createClientWithConfig
  
    -- * Session Operations
  , createSession
  , listSessions
  , getSession
  , deleteSession
  
    -- * Message Operations
  , sendMessage
  , getMessages
  , streamMessages
  
    -- * Agent Operations
  , getAgentState
  , updateAgentState
  
    -- * Tool Operations
  , listTools
  , registerTool
  , unregisterTool
  
    -- * Model Operations
  , listModels
  , getModel
  
    -- * Health Check
  , healthCheck
  ) where

import Core.Types
import Core.HTTP
import Data.Text (Text)
import qualified Data.Text as T

-- | SDK client
data SDKClient = SDKClient
  { clientConfig    :: SDKConfig
  , clientHTTP      :: HTTPClient
  }

-- | Create a new SDK client with default config
createClient :: Text -> Int -> IO SDKClient
createClient host port = do
  let config = defaultConfig { configHost = host, configPort = port }
  createClientWithConfig config

-- | Create a new SDK client with custom config
createClientWithConfig :: SDKConfig -> IO SDKClient
createClientWithConfig config = do
  http <- createHTTPClient (configHost config) (configPort config)
  return $ SDKClient config http

-- | Create a new session
createSession :: SDKClient -> IO (Either SDKError SessionId)
createSession client = do
  result <- httpPost (clientHTTP client) "/api/sessions" ()
  return $ fmap (\r -> r .: "id") result

-- | List all sessions
listSessions :: SDKClient -> IO (Either SDKError [SessionId])
listSessions client = do
  result <- httpGet (clientHTTP client) "/api/sessions"
  return $ fmap (\r -> r .: "sessions") result

-- | Get a session by ID
getSession :: SDKClient -> SessionId -> IO (Either SDKError SessionEvent)
getSession client sessionId = do
  result <- httpGet (clientHTTP client) ("/api/sessions/" ++ sessionId)
  return $ fmap (\r -> r .: "session") result

-- | Delete a session
deleteSession :: SDKClient -> SessionId -> IO (Either SDKError ())
deleteSession client sessionId = do
  result <- httpDelete (clientHTTP client) ("/api/sessions/" ++ sessionId)
  return $ fmap (const ()) result

-- | Send a message to a session
sendMessage :: SDKClient -> SessionId -> Text -> IO (Either SDKError StreamChunk)
sendMessage client sessionId content = do
  let message = Message "user" content
  result <- httpPost (clientHTTP client) ("/api/sessions/" ++ sessionId ++ "/messages") message
  return $ fmap (\r -> r .: "response") result

-- | Get messages from a session
getMessages :: SDKClient -> SessionId -> IO (Either SDKError [Message])
getMessages client sessionId = do
  result <- httpGet (clientHTTP client) ("/api/sessions/" ++ sessionId ++ "/messages")
  return $ fmap (\r -> r .: "messages") result

-- | Stream messages from a session (placeholder)
streamMessages :: SDKClient -> SessionId -> (StreamChunk -> IO ()) -> IO (Either SDKError ())
streamMessages client sessionId callback = do
  -- Placeholder: implement SSE streaming
  return $ Right ()

-- | Get agent state
getAgentState :: SDKClient -> AgentId -> IO (Either SDKError AgentState)
getAgentState client agentId = do
  result <- httpGet (clientHTTP client) ("/api/agents/" ++ agentId)
  return $ fmap (\r -> r .: "state") result

-- | Update agent state
updateAgentState :: SDKClient -> AgentId -> AgentState -> IO (Either SDKError ())
updateAgentState client agentId state = do
  result <- httpPut (clientHTTP client) ("/api/agents/" ++ agentId) state
  return $ fmap (const ()) result

-- | List all tools
listTools :: SDKClient -> IO (Either SDKError [Tool])
listTools client = do
  result <- httpGet (clientHTTP client) "/api/tools"
  return $ fmap (\r -> r .: "tools") result

-- | Register a tool
registerTool :: SDKClient -> Tool -> IO (Either SDKError ())
registerTool client tool = do
  result <- httpPost (clientHTTP client) "/api/tools" tool
  return $ fmap (const ()) result

-- | Unregister a tool
unregisterTool :: SDKClient -> ToolName -> IO (Either SDKError ())
unregisterTool client toolName = do
  result <- httpDelete (clientHTTP client) ("/api/tools/" ++ toolName)
  return $ fmap (const ()) result

-- | List all models
listModels :: SDKClient -> IO (Either SDKError [ModelInfo])
listModels client = do
  result <- httpGet (clientHTTP client) "/api/models"
  return $ fmap (\r -> r .: "models") result

-- | Get a model by name
getModel :: SDKClient -> Text -> IO (Either SDKError ModelInfo)
getModel client modelName = do
  result <- httpGet (clientHTTP client) ("/api/models/" ++ T.unpack modelName)
  return $ fmap (\r -> r .: "model") result

-- | Health check
healthCheck :: SDKClient -> IO (Either SDKError Bool)
healthCheck client = do
  result <- httpGet (clientHTTP client) "/api/health"
  return $ fmap (\r -> r .: "status") result