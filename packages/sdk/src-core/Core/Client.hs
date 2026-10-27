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
import Data.Aeson (FromJSON, Object)
import Data.Aeson.Key (Key)
import Data.Aeson.Types (parseEither, (.:))
import Data.Text (Text)
import qualified Data.Text as T

-- | Decode one field out of a JSON object, mapping the failure to SDKError.
decodeField :: FromJSON a => Key -> Object -> Either SDKError a
decodeField key obj = either (Left . ValidationError . T.pack) Right (parseEither (.: key) obj)

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
  pure $ result >>= decodeField "id"

-- | List all sessions
listSessions :: SDKClient -> IO (Either SDKError [SessionId])
listSessions client = do
  result <- httpGet (clientHTTP client) "/api/sessions"
  pure $ result >>= decodeField "sessions"

-- | Get a session by ID
getSession :: SDKClient -> SessionId -> IO (Either SDKError SessionEvent)
getSession client sessionId = do
  result <- httpGet (clientHTTP client) ("/api/sessions/" ++ sessionId)
  pure $ result >>= decodeField "session"

-- | Delete a session
deleteSession :: SDKClient -> SessionId -> IO (Either SDKError ())
deleteSession client sessionId = do
  result <- httpDelete (clientHTTP client) ("/api/sessions/" ++ sessionId) :: IO (Either SDKError ())
  return $ fmap (const ()) result

-- | Send a message to a session
sendMessage :: SDKClient -> SessionId -> Text -> IO (Either SDKError StreamChunk)
sendMessage client sessionId content = do
  let message = Message "user" content
  result <- httpPost (clientHTTP client) ("/api/sessions/" ++ sessionId ++ "/messages") message
  pure $ result >>= decodeField "response"

-- | Get messages from a session
getMessages :: SDKClient -> SessionId -> IO (Either SDKError [Message])
getMessages client sessionId = do
  result <- httpGet (clientHTTP client) ("/api/sessions/" ++ sessionId ++ "/messages")
  pure $ result >>= decodeField "messages"

-- | Stream messages from a session (placeholder)
streamMessages :: SDKClient -> SessionId -> (StreamChunk -> IO ()) -> IO (Either SDKError ())
streamMessages client sessionId callback = do
  -- Placeholder: implement SSE streaming
  return $ Right ()

-- | Get agent state
getAgentState :: SDKClient -> AgentId -> IO (Either SDKError AgentState)
getAgentState client agentId = do
  result <- httpGet (clientHTTP client) ("/api/agents/" ++ agentId)
  pure $ result >>= decodeField "state"

-- | Update agent state
updateAgentState :: SDKClient -> AgentId -> AgentState -> IO (Either SDKError ())
updateAgentState client agentId state = do
  result <- httpPut (clientHTTP client) ("/api/agents/" ++ agentId) state :: IO (Either SDKError ())
  return $ fmap (const ()) result

-- | List all tools
listTools :: SDKClient -> IO (Either SDKError [Tool])
listTools client = do
  result <- httpGet (clientHTTP client) "/api/tools"
  pure $ result >>= decodeField "tools"

-- | Register a tool
registerTool :: SDKClient -> Tool -> IO (Either SDKError ())
registerTool client tool = do
  result <- httpPost (clientHTTP client) "/api/tools" tool :: IO (Either SDKError ())
  return $ fmap (const ()) result

-- | Unregister a tool
unregisterTool :: SDKClient -> ToolName -> IO (Either SDKError ())
unregisterTool client toolName = do
  result <- httpDelete (clientHTTP client) ("/api/tools/" ++ toolName) :: IO (Either SDKError ())
  return $ fmap (const ()) result

-- | List all models
listModels :: SDKClient -> IO (Either SDKError [ModelInfo])
listModels client = do
  result <- httpGet (clientHTTP client) "/api/models"
  pure $ result >>= decodeField "models"

-- | Get a model by name
getModel :: SDKClient -> Text -> IO (Either SDKError ModelInfo)
getModel client modelName = do
  result <- httpGet (clientHTTP client) ("/api/models/" ++ T.unpack modelName)
  pure $ result >>= decodeField "model"

-- | Health check
healthCheck :: SDKClient -> IO (Either SDKError Bool)
healthCheck client = do
  result <- httpGet (clientHTTP client) "/api/health"
  pure $ result >>= decodeField "status"