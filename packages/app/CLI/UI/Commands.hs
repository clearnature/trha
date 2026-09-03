{-# LANGUAGE OverloadedStrings #-}

module UI.Commands
  ( -- * Commands
    Command(..)
  , parseCommand
  , executeCommand
  ) where

import Data.Text (Text)
import qualified Data.Text as T

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
executeCommand :: Command -> IO (Maybe Text)
executeCommand Help = return $ Just $ T.unlines
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

executeCommand Quit = return Nothing

executeCommand Sessions = do
  -- TODO: Implement session listing
  return $ Just "Sessions: (not implemented)"

executeCommand CreateSession = do
  -- TODO: Implement session creation
  return $ Just "Session created: (not implemented)"

executeCommand (DeleteSession sid) = do
  -- TODO: Implement session deletion
  return $ Just $ "Session deleted: " <> T.pack sid

executeCommand Models = do
  -- TODO: Implement model listing
  return $ Just "Models: deepseek-chat, mimo-v2.5-pro"

executeCommand (SelectModel name) = do
  -- TODO: Implement model selection
  return $ Just $ "Model selected: " <> name

executeCommand Clear = do
  -- TODO: Implement screen clearing
  return $ Just "Screen cleared"

executeCommand Status = do
  -- TODO: Implement status display
  return $ Just "Status: Ready"

executeCommand (SendMessage msg) = do
  -- TODO: Implement message sending
  return $ Just $ "Message sent: " <> msg