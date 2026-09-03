{-# LANGUAGE OverloadedStrings #-}

module UI.Session
  ( -- * Session UI
    listSessionsUI
  , createSessionUI
  , deleteSessionUI
  , getSessionUI
  ) where

import Core.Types
import Core.Client
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO

-- | List all sessions
listSessionsUI :: CLIClient -> IO ()
listSessionsUI client = do
  result <- listSessions client
  case result of
    Right sessions -> do
      if null sessions
        then putStrLn "No sessions found"
        else do
          putStrLn "Sessions:"
          mapM_ (\s -> putStrLn $ "  - " ++ s) sessions
    Left err -> putStrLn $ "Error: " ++ show err

-- | Create a new session
createSessionUI :: CLIClient -> IO ()
createSessionUI client = do
  result <- createSession client
  case result of
    Right sessionId -> putStrLn $ "Created session: " ++ sessionId
    Left err -> putStrLn $ "Error: " ++ show err

-- | Delete a session
deleteSessionUI :: CLIClient -> SessionId -> IO ()
deleteSessionUI client sessionId = do
  result <- deleteSession client sessionId
  case result of
    Right () -> putStrLn $ "Deleted session: " ++ sessionId
    Left err -> putStrLn $ "Error: " ++ show err

-- | Get a session
getSessionUI :: CLIClient -> SessionId -> IO ()
getSessionUI client sessionId = do
  result <- getSession client sessionId
  case result of
    Right event -> putStrLn $ "Session event: " ++ show event
    Left err -> putStrLn $ "Error: " ++ show err