{-# LANGUAGE OverloadedStrings #-}

module Main where

import Core.Types
import Core.Client
import Client.Session
import Client.Agent
import Client.Tool
import Client.Model
import Utils.Logger
import Data.Text (Text)

main :: IO ()
main = do
  -- Create logger
  let logger = createLogger Info "example"
  
  -- Create SDK client
  sdk <- createClient "localhost" 3000
  
  -- Create sub-clients
  let sessionClient = createSessionClient sdk
  let agentClient = createAgentClient sdk
  let toolClient = createToolClient sdk
  let modelClient = createModelClient sdk
  
  -- Log start
  logInfo logger "Starting example..."
  
  -- Create a session
  result <- Client.Session.create sessionClient
  case result of
    Right sessionId -> do
      logInfo logger $ "Created session: " <> sessionId
      
      -- Send a message
      response <- Client.Session.sendMessage sessionClient sessionId "Hello, world!"
      case response of
        Right chunk -> logInfo logger $ "Got response: " <> show chunk
        Left err -> logError logger $ "Error sending message: " <> show err
      
      -- Get messages
      messages <- Client.Session.getMessages sessionClient sessionId
      case messages of
        Right msgs -> logInfo logger $ "Got " <> show (length msgs) <> " messages"
        Left err -> logError logger $ "Error getting messages: " <> show err
      
    Left err -> logError logger $ "Error creating session: " <> show err
  
  -- List models
  models <- Client.Model.list modelClient
  case models of
    Right modelList -> do
      logInfo logger $ "Available models: " <> show (length modelList)
      mapM_ (\m -> logInfo logger $ "  - " <> modelName m) modelList
    Left err -> logError logger $ "Error listing models: " <> show err
  
  -- Health check
  health <- healthCheck sdk
  case health of
    Right True -> logInfo logger "Server is healthy"
    Right False -> logWarning logger "Server is unhealthy"
    Left err -> logError logger $ "Health check failed: " <> show err
  
  logInfo logger "Example completed."