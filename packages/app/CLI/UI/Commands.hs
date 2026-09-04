{-# LANGUAGE OverloadedStrings #-}

module UI.Commands
  ( -- * Commands
    Command(..)
  , parseCommand
  , executeCommand
  ) where

import Core.Types
import Bridge.Scheduler (SchedulerBridge, listSessions, createSession, deleteSession, sendMessage, listModels)
import Data.IORef
import Data.Text (Text)
import qualified Data.Text as T
import System.Process (callCommand)

-- | CLI commands
data Command
  = Help
  | Quit
  | Sessions
  | CreateSession
  | DeleteSession String
  | Models
  | SelectModel Text
  | SendMessage Text
  | Clear
  | Status
  | Unknown Text
  deriving (Show, Eq)

-- | Parse a command from input
parseCommand :: Text -> Command
parseCommand input = case T.words (T.strip input) of
  ["/help"] -> Help
  ["/quit"] -> Quit
  ["/exit"] -> Quit
  ["/sessions"] -> Sessions
  ["/new"] -> CreateSession
  ["/delete", sid] -> DeleteSession (T.unpack sid)
  ["/models"] -> Models
  ["/model", name] -> SelectModel name
  ["/clear"] -> Clear
  ["/status"] -> Status
  _ -> SendMessage input

-- | Execute a command
executeCommand :: SchedulerBridge -> IORef (Maybe SessionId) -> IORef Text -> Command -> IO (Maybe Text)
executeCommand _ _ _ Help = return $ Just $ T.unlines
  [ "Available commands:"
  , "  /help        - Show this help"
  , "  /quit        - Exit the application"
  , "  /sessions    - List all sessions"
  , "  /new         - Create a new session"
  , "  /delete <id> - Delete a session"
  , "  /models      - List available models"
  , "  /model <name> - Select a model"
  , "  /clear       - Clear the screen"
  , "  /status      - Show current status"
  , "  <message>    - Send a message"
  ]

executeCommand _ _ _ Quit = return Nothing

executeCommand bridge _ _ Sessions = do
  result <- listSessions bridge
  return $ Just $ case result of
    Right sessions -> if null sessions
      then "No active sessions"
      else "Sessions:\n" <> T.unlines (map (\s -> "  - " <> T.pack s) sessions)
    Left err -> "Error: " <> T.pack (show err)

executeCommand bridge sessionRef _ CreateSession = do
  result <- createSession bridge
  case result of
    Right sid -> do
      writeIORef sessionRef (Just sid)
      return $ Just $ "Session created: " <> T.pack sid
    Left err -> return $ Just $ "Error: " <> T.pack (show err)

executeCommand bridge sessionRef _ (DeleteSession sid) = do
  result <- deleteSession bridge sid
  current <- readIORef sessionRef
  case current of
    Just currentSid | currentSid == sid -> writeIORef sessionRef Nothing
    _ -> return ()
  return $ Just $ case result of
    Right () -> "Session deleted: " <> T.pack sid
    Left err -> "Error: " <> T.pack (show err)

executeCommand bridge _ _ Models = do
  result <- listModels bridge
  return $ Just $ case result of
    Right models -> if null models
      then "No models available"
      else "Models:\n" <> T.unlines (map (\m -> "  - " <> modelName m <> " (" <> modelDescription m <> ")") models)
    Left err -> "Error: " <> T.pack (show err)

executeCommand _ _ modelRef (SelectModel name) = do
  writeIORef modelRef name
  return $ Just $ "Model selected: " <> name

executeCommand _ _ _ Clear = do
  callCommand "clear"
  return Nothing

executeCommand _ sessionRef modelRef Status = do
  session <- readIORef sessionRef
  model <- readIORef modelRef
  return $ Just $ T.unlines
    [ "Status:"
    , "  Current session: " <> maybe "none" T.pack session
    , "  Current model: " <> model
    ]

executeCommand bridge sessionRef _ (SendMessage msg) = do
  session <- readIORef sessionRef
  case session of
    Nothing -> return $ Just "No active session. Use /new to create one."
    Just sid -> do
      result <- sendMessage bridge sid msg
      return $ Just $ case result of
        Right chunk -> case chunk of
          ChunkDelta text -> text
          ChunkToolCall name args -> "[Tool call: " <> T.pack name <> " " <> T.unwords args <> "]"
          ChunkDone usage -> "[Done: " <> T.pack (show (usageTotalTokens usage)) <> " tokens]"
        Left err -> "Error: " <> T.pack (show err)