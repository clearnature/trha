{-# LANGUAGE OverloadedStrings #-}

module Main where

import Core.Types
import Bridge.Scheduler
import Config.Settings
import UI.Brick (runTUI)
import UI.Commands
import Data.IORef
import Data.Text (Text)
import qualified Data.Text as T
import Options.Applicative

-- | Global options (shared across subcommands)
data GlobalOpts = GlobalOpts
  { optHost  :: Maybe Text
  , optPort  :: Maybe Int
  , optModel :: Maybe Text
  } deriving (Show)

-- | Subcommand
data SubCommand
  = CmdTUI
  | CmdCLI
  | CmdServe
  deriving (Show)

-- | Global options parser
globalOptsParser :: Parser GlobalOpts
globalOptsParser = GlobalOpts
  <$> optional (strOption
        ( long "host"
        <> short 'h'
        <> metavar "HOST"
        <> help "Server host (default: localhost)"
        ))
  <*> optional (option auto
        ( long "port"
        <> short 'p'
        <> metavar "PORT"
        <> help "Server port (default: 3000)"
        ))
  <*> optional (strOption
        ( long "model"
        <> short 'm'
        <> metavar "MODEL"
        <> help "Model name (default: deepseek-chat)"
        ))

-- | TUI subcommand
tuiParser :: Parser SubCommand
tuiParser = pure CmdTUI

-- | CLI subcommand
cliParser :: Parser SubCommand
cliParser = pure CmdCLI

-- | Serve subcommand
serveParser :: Parser SubCommand
serveParser = pure CmdServe

-- | Command parser with subcommands
commandParser :: Parser (GlobalOpts, SubCommand)
commandParser = (,)
  <$> globalOptsParser
  <*> subparser
        ( command "tui"
            (info tuiParser
              (progDesc "Run in TUI mode (fullscreen terminal UI)"))
        <> command "cli"
            (info cliParser
              (progDesc "Run in CLI mode (interactive REPL)"))
        <> command "serve"
            (info serveParser
              (progDesc "Start API server"))
        )

-- | Build CLIConfig from global options
buildConfig :: GlobalOpts -> IO CLIConfig
buildConfig opts = do
  config <- loadConfig
  let baseConfig = case config of
        Just c -> c
        Nothing -> defaultCLIConfig
  return baseConfig
    { configHost = maybe (configHost baseConfig) id (optHost opts)
    , configPort = maybe (configPort baseConfig) id (optPort opts)
    , configModel = maybe (configModel baseConfig) id (optModel opts)
    }

-- | Run TUI mode
runTUIMode :: CLIConfig -> IO ()
runTUIMode config = do
  putStrLn "Starting TUI mode..."
  putStrLn "Press Ctrl+Q to quit"
  bridge <- createSchedulerBridge config
  runTUI bridge (configModel config)

-- | Run CLI mode
runCLIMode :: CLIConfig -> IO ()
runCLIMode config = do
  putStrLn "gh-harness CLI"
  putStrLn "Type '/help' for commands, '/quit' to exit"
  bridge <- createSchedulerBridge config
  sessionRef <- newIORef (Nothing :: Maybe SessionId)
  modelRef <- newIORef (configModel config)
  repl bridge sessionRef modelRef

-- | Run serve mode
runServeMode :: CLIConfig -> IO ()
runServeMode config = do
  putStrLn $ "Starting API server on " ++ T.unpack (configHost config) ++ ":" ++ show (configPort config)
  putStrLn "TODO: Implement API server startup"
  -- TODO: Import and call API.Server.startServer

-- | REPL loop
repl :: SchedulerBridge -> IORef (Maybe SessionId) -> IORef Text -> IO ()
repl bridge sessionRef modelRef = do
  putStr "> "
  input <- getLine
  let command = parseCommand (T.pack input)
  case command of
    Quit -> putStrLn "Goodbye!"
    _ -> do
      result <- executeCommand bridge sessionRef modelRef command
      case result of
        Just msg -> putStrLn $ T.unpack msg
        Nothing -> return ()
      repl bridge sessionRef modelRef

-- | Main entry point
main :: IO ()
main = do
  (opts, cmd) <- execParser opts'
  config <- buildConfig opts
  case cmd of
    CmdTUI   -> runTUIMode config
    CmdCLI   -> runCLIMode config
    CmdServe -> runServeMode config
  where
    opts' = info (commandParser <**> helper)
      ( fullDesc
      <> progDesc "gh-harness agent harness"
      <> header "gh-harness - A microkernel agent harness"
      )
