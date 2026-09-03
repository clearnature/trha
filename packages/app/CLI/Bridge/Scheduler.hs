{-# LANGUAGE OverloadedStrings #-}

module Bridge.Scheduler
  ( -- * Scheduler Bridge
    SchedulerBridge(..)
  , createSchedulerBridge
  
    -- * Session Operations
  , createSession
  , listSessions
  , getSession
  , deleteSession
  
    -- * Message Operations
  , sendMessage
  , getMessages
  
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

-- | Scheduler bridge
data SchedulerBridge = SchedulerBridge
  { bridgeConfig :: CLIConfig
  , bridgeHTTP   :: HTTPClient
  }

-- | Create a new scheduler bridge
createSchedulerBridge :: CLIConfig -> IO SchedulerBridge
createSchedulerBridge config = do
  http <- createHTTPClient (configHost config) (configPort config)
  return $ SchedulerBridge config http

-- | Create a new session
createSession :: SchedulerBridge -> IO (Either CLIError SessionId)
createSession bridge = do
  result <- httpGet (bridgeHTTP bridge) "/api/sessions"
  return $ case result of
    Right (Object r) -> case parseMaybe (.: "id") r of
      Just sessionId -> Right sessionId
      Nothing -> Left $ ValidationError "Missing session ID"
    Right _ -> Left $ ValidationError "Invalid response"
    Left err -> Left err

-- | List all sessions
listSessions :: SchedulerBridge -> IO (Either CLIError [SessionId])
listSessions bridge = do
  result <- httpGet (bridgeHTTP bridge) "/api/sessions"
  return $ case result of
    Right (Object r) -> case parseMaybe (.: "sessions") r of
      Just sessions -> Right sessions
      Nothing -> Left $ ValidationError "Missing sessions"
    Right _ -> Left $ ValidationError "Invalid response"
    Left err -> Left err

-- | Get a session by ID
getSession :: SchedulerBridge -> SessionId -> IO (Either CLIError SessionEvent)
getSession bridge sessionId = do
  result <- httpGet (bridgeHTTP bridge) ("/api/sessions/" ++ sessionId)
  return $ case result of
    Right (Object r) -> case parseMaybe (.: "session") r of
      Just event -> Right event
      Nothing -> Left $ ValidationError "Missing session event"
    Right _ -> Left $ ValidationError "Invalid response"
    Left err -> Left err

-- | Delete a session
deleteSession :: SchedulerBridge -> SessionId -> IO (Either CLIError ())
deleteSession bridge sessionId = do
  result <- httpDelete (bridgeHTTP bridge) ("/api/sessions/" ++ sessionId) :: IO (Either CLIError Value)
  return $ fmap (const ()) result

-- | Send a message to a session
sendMessage :: SchedulerBridge -> SessionId -> Text -> IO (Either CLIError StreamChunk)
sendMessage bridge sessionId content = do
  let message = Message "user" content
  result <- httpPost (bridgeHTTP bridge) ("/api/sessions/" ++ sessionId ++ "/messages") message
  return $ case result of
    Right (Object r) -> case parseMaybe (.: "response") r of
      Just chunk -> Right chunk
      Nothing -> Left $ ValidationError "Missing response"
    Right _ -> Left $ ValidationError "Invalid response"
    Left err -> Left err

-- | Get messages from a session
getMessages :: SchedulerBridge -> SessionId -> IO (Either CLIError [Message])
getMessages bridge sessionId = do
  result <- httpGet (bridgeHTTP bridge) ("/api/sessions/" ++ sessionId ++ "/messages")
  return $ case result of
    Right (Object r) -> case parseMaybe (.: "messages") r of
      Just messages -> Right messages
      Nothing -> Left $ ValidationError "Missing messages"
    Right _ -> Left $ ValidationError "Invalid response"
    Left err -> Left err

-- | Get agent state
getAgentState :: SchedulerBridge -> AgentId -> IO (Either CLIError AgentState)
getAgentState bridge agentId = do
  result <- httpGet (bridgeHTTP bridge) ("/api/agents/" ++ agentId)
  return $ case result of
    Right (Object r) -> case parseMaybe (.: "state") r of
      Just state -> Right state
      Nothing -> Left $ ValidationError "Missing state"
    Right _ -> Left $ ValidationError "Invalid response"
    Left err -> Left err

-- | Update agent state
updateAgentState :: SchedulerBridge -> AgentId -> AgentState -> IO (Either CLIError ())
updateAgentState bridge agentId state = do
  result <- httpPut (bridgeHTTP bridge) ("/api/agents/" ++ agentId) state :: IO (Either CLIError Value)
  return $ fmap (const ()) result

-- | List all models
listModels :: SchedulerBridge -> IO (Either CLIError [ModelInfo])
listModels bridge = do
  result <- httpGet (bridgeHTTP bridge) "/api/models"
  return $ case result of
    Right (Object r) -> case parseMaybe (.: "models") r of
      Just models -> Right models
      Nothing -> Left $ ValidationError "Missing models"
    Right _ -> Left $ ValidationError "Invalid response"
    Left err -> Left err

-- | Get a model by name
getModel :: SchedulerBridge -> Text -> IO (Either CLIError ModelInfo)
getModel bridge modelName = do
  result <- httpGet (bridgeHTTP bridge) ("/api/models/" ++ show modelName)
  return $ case result of
    Right (Object r) -> case parseMaybe (.: "model") r of
      Just model -> Right model
      Nothing -> Left $ ValidationError "Missing model"
    Right _ -> Left $ ValidationError "Invalid response"
    Left err -> Left err

-- | Health check
healthCheck :: SchedulerBridge -> IO (Either CLIError Bool)
healthCheck bridge = do
  result <- httpGet (bridgeHTTP bridge) "/api/health"
  return $ case result of
    Right (Object r) -> case parseMaybe (.: "status") r of
      Just status -> Right status
      Nothing -> Left $ ValidationError "Missing status"
    Right _ -> Left $ ValidationError "Invalid response"
    Left err -> Left err