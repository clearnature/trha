{-# LANGUAGE OverloadedStrings #-}

module Core.Client
  ( -- * Client
    CLIClient(..)
  , createCLIClient
  
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
  
    -- * Model Operations
  , listModels
  , getModel
  
    -- * Health Check
  , healthCheck
  ) where

import Core.Types
import Core.HTTP
import Data.Aeson
import Data.Aeson.Types (parseMaybe)
import Data.Text (Text)

-- | CLI client
data CLIClient = CLIClient
  { clientConfig :: CLIConfig
  , clientHTTP   :: HTTPClient
  }

-- | Create a new CLI client
createCLIClient :: CLIConfig -> IO CLIClient
createCLIClient config = do
  http <- createHTTPClient (configHost config) (configPort config)
  return $ CLIClient config http

-- | Create a new session
createSession :: CLIClient -> IO (Either CLIError SessionId)
createSession client = do
  result <- httpGet (clientHTTP client) "/api/sessions"
  return $ case result of
    Right (Object r) -> case parseMaybe (.: "id") r of
      Just sessionId -> Right sessionId
      Nothing -> Left $ ValidationError "Missing session ID"
    Right _ -> Left $ ValidationError "Invalid response"
    Left err -> Left err

-- | List all sessions
listSessions :: CLIClient -> IO (Either CLIError [SessionId])
listSessions client = do
  result <- httpGet (clientHTTP client) "/api/sessions"
  return $ case result of
    Right (Object r) -> case parseMaybe (.: "sessions") r of
      Just sessions -> Right sessions
      Nothing -> Left $ ValidationError "Missing sessions"
    Right _ -> Left $ ValidationError "Invalid response"
    Left err -> Left err

-- | Get a session by ID
getSession :: CLIClient -> SessionId -> IO (Either CLIError SessionEvent)
getSession client sessionId = do
  result <- httpGet (clientHTTP client) ("/api/sessions/" ++ sessionId)
  return $ case result of
    Right (Object r) -> case parseMaybe (.: "session") r of
      Just event -> Right event
      Nothing -> Left $ ValidationError "Missing session event"
    Right _ -> Left $ ValidationError "Invalid response"
    Left err -> Left err

-- | Delete a session
deleteSession :: CLIClient -> SessionId -> IO (Either CLIError ())
deleteSession client sessionId = do
  result <- httpDelete (clientHTTP client) ("/api/sessions/" ++ sessionId) :: IO (Either CLIError Value)
  return $ fmap (const ()) result

-- | Send a message to a session
sendMessage :: CLIClient -> SessionId -> Text -> IO (Either CLIError StreamChunk)
sendMessage client sessionId content = do
  let message = Message "user" content
  result <- httpPost (clientHTTP client) ("/api/sessions/" ++ sessionId ++ "/messages") message
  return $ case result of
    Right (Object r) -> case parseMaybe (.: "response") r of
      Just chunk -> Right chunk
      Nothing -> Left $ ValidationError "Missing response"
    Right _ -> Left $ ValidationError "Invalid response"
    Left err -> Left err

-- | Get messages from a session
getMessages :: CLIClient -> SessionId -> IO (Either CLIError [Message])
getMessages client sessionId = do
  result <- httpGet (clientHTTP client) ("/api/sessions/" ++ sessionId ++ "/messages")
  return $ case result of
    Right (Object r) -> case parseMaybe (.: "messages") r of
      Just messages -> Right messages
      Nothing -> Left $ ValidationError "Missing messages"
    Right _ -> Left $ ValidationError "Invalid response"
    Left err -> Left err

-- | Stream messages from a session (placeholder)
streamMessages :: CLIClient -> SessionId -> (StreamChunk -> IO ()) -> IO (Either CLIError ())
streamMessages client sessionId callback = do
  -- Placeholder: implement SSE streaming
  return $ Right ()

-- | Get agent state
getAgentState :: CLIClient -> AgentId -> IO (Either CLIError AgentState)
getAgentState client agentId = do
  result <- httpGet (clientHTTP client) ("/api/agents/" ++ agentId)
  return $ case result of
    Right (Object r) -> case parseMaybe (.: "state") r of
      Just state -> Right state
      Nothing -> Left $ ValidationError "Missing state"
    Right _ -> Left $ ValidationError "Invalid response"
    Left err -> Left err

-- | Update agent state
updateAgentState :: CLIClient -> AgentId -> AgentState -> IO (Either CLIError ())
updateAgentState client agentId state = do
  result <- httpPut (clientHTTP client) ("/api/agents/" ++ agentId) state :: IO (Either CLIError Value)
  return $ fmap (const ()) result

-- | List all models
listModels :: CLIClient -> IO (Either CLIError [ModelInfo])
listModels client = do
  result <- httpGet (clientHTTP client) "/api/models"
  return $ case result of
    Right (Object r) -> case parseMaybe (.: "models") r of
      Just models -> Right models
      Nothing -> Left $ ValidationError "Missing models"
    Right _ -> Left $ ValidationError "Invalid response"
    Left err -> Left err

-- | Get a model by name
getModel :: CLIClient -> Text -> IO (Either CLIError ModelInfo)
getModel client modelName = do
  result <- httpGet (clientHTTP client) ("/api/models/" ++ show modelName)
  return $ case result of
    Right (Object r) -> case parseMaybe (.: "model") r of
      Just model -> Right model
      Nothing -> Left $ ValidationError "Missing model"
    Right _ -> Left $ ValidationError "Invalid response"
    Left err -> Left err

-- | Health check
healthCheck :: CLIClient -> IO (Either CLIError Bool)
healthCheck client = do
  result <- httpGet (clientHTTP client) "/api/health"
  return $ case result of
    Right (Object r) -> case parseMaybe (.: "status") r of
      Just status -> Right status
      Nothing -> Left $ ValidationError "Missing status"
    Right _ -> Left $ ValidationError "Invalid response"
    Left err -> Left err