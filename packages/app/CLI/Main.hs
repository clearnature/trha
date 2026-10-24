{-# LANGUAGE OverloadedStrings #-}

module Main where

import Core.Types
import Core.Args
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
import Control.Applicative ((<|>))
import System.Environment (lookupEnv)
import System.Exit (ExitCode(ExitFailure), exitWith)
import System.FilePath ((</>))
import System.IO (hFlush, hIsTerminalDevice, hPutStrLn, stderr, stdin, stdout, hSetEncoding, utf8)

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

-- | Run TUI mode.
--
-- The brick UI drives the terminal directly, so a pipe (or @/dev/null@) has no
-- meaning here: vty would fail with @hWaitForInput: end of file@ from inside
-- the event loop. Say what is wrong instead, and point at @trha cli@, which is
-- line-oriented and works on a pipe.
runTUIMode :: CLIConfig -> IO ()
runTUIMode config = do
  tty <- hIsTerminalDevice stdin
  if not tty
    then do
      hPutStrLn stderr "trha: the TUI needs an interactive terminal (stdin is not a tty)."
      hPutStrLn stderr "      Run `trha cli` for the line-based REPL, or `trha --help`."
      exitWith (ExitFailure 2)
    else do
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
--
-- The state directory resolves in the usual order: flag, then @TRHA_STATE_DIR@.
-- The Desktop app already exports that variable to the scheduler it spawns,
-- so an operator who runs the kernel from the same shell gets kernel-side
-- session persistence without repeating the path. Absent both, the kernel is
-- in-memory only (and says so).
runServeMode :: Int -> Maybe FilePath -> CLIConfig -> IO ()
runServeMode kernelPort cliStateDir config = do
  envStateDir <- lookupEnv "TRHA_STATE_DIR"
  let stateDir = cliStateDir <|> envStateDir
  putStrLn $ "Starting API server on " ++ T.unpack (configHost config) ++ ":" ++ show kernelPort
            ++ maybe " (sessions: in-memory only)" (\d -> " (sessions: " ++ d ++ ")") stateDir
  API.Server.startStubKernel kernelPort stateDir

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
  (opts, mcmd) <- execParser cliParserInfo
  config <- buildConfig opts
  case resolveCommand mcmd of
    CmdTUI   -> runTUIMode config
    CmdCLI   -> runCLIMode config
    CmdServe kernelPort stateDir -> runServeMode kernelPort stateDir config
    CmdSettingsSchema -> putStrLn (T.unpack settingsSchemaJson)
