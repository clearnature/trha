{-# LANGUAGE OverloadedStrings #-}

module UI.Main
  ( -- * Main UI
    main
  , runCLI
  ) where

import Core.Types
import Core.Client
import UI.Terminal
import UI.Session
import UI.Model
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO

-- | Main entry point
main :: IO ()
main = do
  putStrLn "gh-harness CLI"
  putStrLn "Type 'help' for commands, 'quit' to exit"
  
  -- Create CLI client
  let config = defaultCLIConfig
  client <- createCLIClient config
  
  -- Run CLI loop
  runCLI client

-- | Run CLI loop
runCLI :: CLIClient -> IO ()
runCLI client = do
  putStr "> "
  input <- getLine
  
  case input of
    "quit" -> putStrLn "Goodbye!"
    "help" -> do
      printHelp
      runCLI client
    "sessions" -> do
      listSessionsUI client
      runCLI client
    "models" -> do
      listModelsUI client
      runCLI client
    "health" -> do
      healthResult <- healthCheck client
      case healthResult of
        Right True -> putStrLn "Server is healthy"
        Right False -> putStrLn "Server is unhealthy"
        Left err -> putStrLn $ "Error: " ++ show err
      runCLI client
    _ -> do
      -- Create a new session for each message
      sessionResult <- createSession client
      case sessionResult of
        Right sessionId -> do
          putStrLn $ "Created session: " ++ sessionId
          
          -- Send message
          responseResult <- sendMessage client sessionId (T.pack input)
          case responseResult of
            Right chunk -> do
              putStrLn "Response:"
              printChunk chunk
            Left err -> putStrLn $ "Error: " ++ show err
          
          -- Clean up
          _ <- deleteSession client sessionId
          return ()
          
        Left err -> putStrLn $ "Error creating session: " ++ show err
      
      runCLI client

-- | Print help
printHelp :: IO ()
printHelp = do
  putStrLn "Commands:"
  putStrLn "  help      - Show this help"
  putStrLn "  sessions  - List all sessions"
  putStrLn "  models    - List available models"
  putStrLn "  health    - Check server health"
  putStrLn "  quit      - Exit the program"
  putStrLn "  <message> - Send a message to the agent"

-- | Print a stream chunk
printChunk :: StreamChunk -> IO ()
printChunk (ChunkDelta text) = TIO.putStrLn text
printChunk (ChunkToolCall tool args) = do
  putStrLn $ "Tool call: " ++ tool
  mapM_ (\arg -> putStrLn $ "  - " ++ T.unpack arg) args
printChunk (ChunkDone usage) = do
  putStrLn $ "Usage: " ++ show (usageTotalTokens usage) ++ " tokens"