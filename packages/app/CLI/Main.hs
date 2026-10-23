{-# LANGUAGE OverloadedStrings #-}

module Main where

import Core.Types
import Bridge.Scheduler
import Config.Settings
import qualified API.Server (startStubKernel)
import UI.Brick (runTUI)
import UI.I18n (Lang(..), parseLang, tr)
import UI.Commands
import UI.Commands.Registry (settingsSchemaJson)
import Data.IORef
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Data.Char (isSpace)
import Data.List (isPrefixOf)
import Control.Monad.IO.Class (liftIO)
import Options.Applicative
import System.Console.ANSI
import System.Console.Haskeline
import System.Directory (getHomeDirectory, createDirectoryIfMissing)
import Data.Maybe (fromMaybe)
import System.FilePath ((</>))
import System.IO (hFlush, stdout, hSetEncoding, utf8)

-- | Global options (shared across subcommands)
data GlobalOpts = GlobalOpts
  { optHost  :: Maybe Text
  , optPort  :: Maybe Int
  , optModel :: Maybe Text
  , optTheme :: Maybe Text
  , optLang  :: Maybe Text
  } deriving (Show)

-- | Subcommand
data SubCommand
  = CmdTUI
  | CmdCLI
  | CmdServe Int
  | CmdSettingsSchema
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
        <> help "Server port (default: 3456)"
        ))
  <*> optional (strOption
        ( long "model"
        <> short 'm'
        <> metavar "MODEL"
        <> help "Model name (default: deepseek-chat)"
        ))
  <*> optional (strOption
        ( long "theme"
        <> metavar "THEME"
        <> help "TUI theme: tokyo-night | light (default: tokyo-night)"
        ))
  <*> optional (strOption
        ( long "lang"
        <> metavar "LANG"
        <> help "Interface language: zh | en (default: zh)"
        ))

-- | TUI subcommand
tuiParser :: Parser SubCommand
tuiParser = pure CmdTUI

-- | CLI subcommand
cliParser :: Parser SubCommand
cliParser = pure CmdCLI

-- | Serve subcommand.
--
-- The kernel port is deliberately separate from @configPort@: the latter is
-- how the CLI/TUI reaches the *scheduler* (3456), while this is where the
-- kernel's OpenAI-compatible API listens. 3333 keeps the two from colliding.
serveParser :: Parser SubCommand
serveParser = CmdServe <$> option auto
  ( long "kernel-port"
  <> metavar "PORT"
  <> value 3333
  <> showDefault
  <> help "Kernel API port (default: 3333; the scheduler talks to this)"
  )

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
        <> command "settings-schema"
            (info (pure CmdSettingsSchema)
              (progDesc "Print the machine-readable settings schema (JSON)"))
        )

-- | Build CLIConfig from global options.
-- Ensures ~/.trha/settings.yaml exists (first run writes the default),
-- then applies --host/--port/--model overrides on top of it.
buildConfig :: GlobalOpts -> IO CLIConfig
buildConfig opts = do
  baseConfig <- initConfig
  return baseConfig
    { configHost = fromMaybe (configHost baseConfig) (optHost opts)
    , configPort = fromMaybe (configPort baseConfig) (optPort opts)
    , configModel = fromMaybe (configModel baseConfig) (optModel opts)
    , configTheme = fromMaybe (configTheme baseConfig) (optTheme opts)
    , configLang = fromMaybe (configLang baseConfig) (optLang opts)
    }

-- | Run TUI mode
runTUIMode :: CLIConfig -> IO ()
runTUIMode config = do
  let lang = parseLang (configLang config)
  putStrLn (T.unpack (tr lang "Starting TUI mode..."))
  putStrLn (T.unpack (tr lang "Press Ctrl+Q to quit"))
  bridge <- createSchedulerBridge config
  runTUI bridge config

-- | Run CLI mode
runCLIMode :: CLIConfig -> IO ()
runCLIMode config = do
  hSetEncoding stdout utf8
  let lang = parseLang (configLang config)
  -- Colored banner
  setSGR [SetColor Foreground Vivid Cyan]
  putStrLn "╭─────────────────────╮"
  putStrLn "│ trha · agent harness │"
  putStrLn "╰─────────────────────╯"
  setSGR [Reset]
  setSGR [SetColor Foreground Vivid Black]
  putStrLn (T.unpack (tr lang "Type '/help' for commands, '/quit' to exit"))
  setSGR [Reset]
  bridge <- createSchedulerBridge config
  sessionRef <- newIORef (Nothing :: Maybe SessionId)
  modelRef <- newIORef (configModel config)
  repl bridge sessionRef modelRef lang

-- | Run serve mode: start the kernel's OpenAI-compatible API server so the
-- scheduler (and therefore the CLI/TUI/Desktop shells) can reach it on
-- 127.0.0.1:3333 by default.  The stub adapter supplies a deterministic
-- two-round tool loop, which makes the whole chain work without an LLM key;
-- swap it for a real provider adapter once credentials are configured.
runServeMode :: Int -> CLIConfig -> IO ()
runServeMode kernelPort config = do
  putStrLn $ "Starting API server on " ++ T.unpack (configHost config) ++ ":" ++ show kernelPort
  API.Server.startStubKernel kernelPort

-- | All slash commands for tab completion (derived from the shared
-- registry so REPL completion, TUI picker and parser stay in sync).
slashCommands :: [String]
slashCommands = map T.unpack completions

-- | Complete the trailing word if it is a slash command.
-- Haskeline hands us (reverse-before-word, reverse-word).
completeSlash :: Monad m => CompletionFunc m
completeSlash (revBefore, revWord) = return (before, completions)
  where
    before = reverse revBefore
    word   = reverse revWord
    completions
      | take 1 word == "/" =
          map simpleCompletion (filter (word `isPrefixOf`) slashCommands)
      | otherwise = []

-- | REPL loop with haskeline: history, slash tab-completion, λ prompt
repl :: SchedulerBridge -> IORef (Maybe SessionId) -> IORef Text -> Lang -> IO ()
repl bridge sessionRef modelRef lang = do
  home <- getHomeDirectory
  let histDir = home </> ".trha"
  createDirectoryIfMissing True histDir
  let baseSettings = defaultSettings :: Settings IO
      settings = baseSettings
        { historyFile = Just (histDir </> "history")
        , autoAddHistory = True
        , complete = completeSlash
        }
  runInputT settings loop
  where
    loop :: InputT IO ()
    loop = do
      (model, session) <- liftIO $ do
        m <- readIORef modelRef
        s <- readIORef sessionRef
        setSGR [SetColor Foreground Vivid Black]
        TIO.putStrLn $ " " <> m <> "  │  " <> tr lang "session: " <> maybe (tr lang "none") T.pack s
        setSGR [Reset]
        hFlush stdout
        return (m, s)

      minput <- getInputLine "λ "
      case minput of
        Nothing -> liftIO $ putStrLn (T.unpack (tr lang "Goodbye!"))
        Just input -> do
          let command = parseCommand (T.pack input)
          case command of
            Quit -> liftIO $ putStrLn (T.unpack (tr lang "Goodbye!"))
            _ -> do
              result <- liftIO $ executeCommand lang bridge sessionRef modelRef command
              case result of
                Just msg -> liftIO $ putStrLn (T.unpack msg)
                Nothing -> return ()
              loop

-- | Main entry point
main :: IO ()
main = do
  (opts, cmd) <- execParser opts'
  config <- buildConfig opts
  case cmd of
    CmdTUI   -> runTUIMode config
    CmdCLI   -> runCLIMode config
    CmdServe kernelPort -> runServeMode kernelPort config
    CmdSettingsSchema -> putStrLn (T.unpack settingsSchemaJson)
  where
    opts' = info (commandParser <**> helper)
      ( fullDesc
      <> progDesc "trha agent harness"
      <> header "trha - A microkernel agent harness"
      )
