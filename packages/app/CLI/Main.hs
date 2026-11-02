{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}

module Main where

import Core.Types
import Core.Args
import Core.Sandbox (runSandboxCommand)
import Core.Fonts
import Bridge.Scheduler
import Config.Settings
import Core.RunLog (logDir, logLine)
import Core.RunState
import Core.Bootstrap (ensureBackend)
import Core.ProjectStore (ensureProject)
import UI.SetupWizard (runSetupWizard)
import qualified API.Server (kernelBindAddress, startStubKernel)
import UI.Brick (runTUI)
import UI.InputHistory (historyFilePath)
import UI.CustomCommands (CustomCommand(..), loadCustomCommands)
import UI.I18n (Lang(..), parseLang, tr)
import UI.Commands
import UI.Commands.Registry (settingsSchemaJson)
import Data.IORef
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Data.Char (isSpace, toLower)
import Data.List (isPrefixOf)
import Control.Concurrent.Async (async)
import Control.Monad (forM_, void, when)
import Control.Exception (SomeException, finally, try)
import Control.Monad.IO.Class (liftIO)
import Options.Applicative
import System.Console.ANSI
import System.Console.Haskeline
import System.Directory (getCurrentDirectory)
import Data.Maybe (fromMaybe)
import Control.Applicative ((<|>))
import System.Environment (lookupEnv)
import System.Exit (ExitCode(ExitFailure), exitFailure, exitWith)
import GHC.IO.Encoding (setLocaleEncoding)
import System.IO
  ( BufferMode(LineBuffering), hFlush, hIsTerminalDevice, hPutStrLn, hSetBuffering
  , hSetEncoding, stderr, stdin, stdout, utf8 )
#if defined(mingw32_HOST_OS)
import Foreign.C.Types (CUInt(..))

-- | Windows hands the console code page 936 (GBK) while the program writes
-- UTF-8, so Chinese output renders as 「姝ｅ湪…」.  Switching the output code
-- page to 65001 makes @cabal run@ and the bare exe agree.
foreign import ccall unsafe "SetConsoleOutputCP"
  c_SetConsoleOutputCP :: CUInt -> IO CUInt
#endif

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
    , configAgentPreset = fromMaybe (configAgentPreset baseConfig) (optAgentPreset opts)
    , configToken = fromMaybe (configToken baseConfig) (optToken opts)
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
      putStrLn (T.unpack (tr lang "Press Ctrl+Alt+Q to stop the kernel and scheduler"))
      logLine ("start tui model=" <> configModel config)
      -- 后端启动不能挡在界面之前：brick 必须先接管终端，服务在后台拉起。
      -- 同步等待会让 TUI 停在「正在检查内核与调度器」——Windows 上 spawn 一个
      -- 常驻服务再逐轮做健康检查，最坏要几十秒。结果只写日志：brick 已经接管
      -- stdout，任何 putStrLn 都会破坏画面。
      void $ async $ do
        r <- try (ensureBackend config) :: IO (Either SomeException [Text])
        case r of
          Left e -> logLine ("backend start failed: " <> T.pack (show e))
          Right started ->
            logLine ("backend started: " <> T.intercalate "+" started)
      bridge <- createSchedulerBridge config
      runTUI bridge config
      logLine "exit tui"

-- | Tell the user which services had to be started (silent when both were up).
announceBackend :: [Text] -> IO ()
announceBackend [] = pure ()
announceBackend started = do
  dir <- logDir
  putStrLn ("backend: started " <> T.unpack (T.intercalate " + " started)
            <> " — logs: " <> dir <> "/{kernel,scheduler}.log")

-- | Run CLI mode
runCLIMode :: CLIConfig -> IO ()
runCLIMode config = do
  hSetEncoding stdout utf8
  logLine ("start cli model=" <> configModel config)
  cwd <- getCurrentDirectory
  ensureProject cwd
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
  announceBackend =<< ensureBackend config
  bridge <- createSchedulerBridge config
  sessionRef <- newIORef (Nothing :: Maybe SessionId)
  modelRef <- newIORef (configModel config)
  repl bridge sessionRef modelRef lang

-- | Run serve mode: start the kernel's OpenAI-compatible API server so the
-- scheduler (and therefore the CLI/TUI/Desktop shells) can reach it on
-- 127.0.0.1:19433 by default.  The stub adapter supplies a deterministic
-- two-round tool loop, which makes the whole chain work without an LLM key;
-- swap it for a real provider adapter once credentials are configured.
--
-- The state directory resolves in the usual order: flag, then @TRHA_STATE_DIR@.
-- The Desktop app already exports that variable to the scheduler it spawns,
-- so an operator who runs the kernel from the same shell gets kernel-side
-- session persistence without repeating the path. Absent both, the kernel is
-- in-memory only (and says so).
runServeMode :: Int -> Maybe FilePath -> CLIConfig -> IO ()
runServeMode kernelPort cliStateDir _config = do
  -- stdout is a file when launched as a service: without LineBuffering the
  -- "Starting API server" line (and any later diagnostics) sits in an 8 KiB
  -- block buffer and never reaches ~/.trha/logs/kernel.log.
  hSetBuffering stdout LineBuffering
  envStateDir <- lookupEnv "TRHA_STATE_DIR"
  let stateDir = cliStateDir <|> envStateDir
  outcome <- writePid Kernel
  case outcome of
    PidOwnedBy pid -> do
      hPutStrLn stderr $ "another kernel is already running (pid " ++ show pid
        ++ "); stop it first: trha stop kernel"
      exitFailure
    PidWritten -> do
      putStrLn $ "Starting API server on " ++ API.Server.kernelBindAddress ++ ":" ++ show kernelPort
                ++ maybe " (sessions: in-memory only)" (\d -> " (sessions: " ++ d ++ ")") stateDir
      API.Server.startStubKernel kernelPort stateDir `finally` removePid Kernel

-- | @trha stop [kernel|scheduler|all] [--force]@.
--
-- SIGTERM only; a process that outlives the five-second timeout is reported
-- (non-zero exit) unless @--force@ was given.
runStopMode :: Maybe String -> Bool -> IO ()
runStopMode arg force = case arg of
  Nothing -> stopEverything
  Just raw -> case map toLower raw of
    "all" -> stopEverything
    other -> case parseService other of
      Just svc -> do
        r <- stopService svc force
        putStrLn (stopResultText svc r)
        when (isStopFailure r) exitFailure
      Nothing -> do
        hPutStrLn stderr ("unknown service: " ++ raw ++ " (use kernel | scheduler | all)")
        exitFailure
  where
    stopEverything = do
      rs <- stopAll force
      forM_ rs $ \(svc, r) -> putStrLn (stopResultText svc r)
      when (any (isStopFailure . snd) rs) exitFailure

isStopFailure :: StopResult -> Bool
isStopFailure NotRunning    = False
isStopFailure Stopped{}     = False
isStopFailure Forced{}      = False
isStopFailure _             = True

-- | @trha status@: pids and liveness, no side effects.
runStatusMode :: IO ()
runStatusMode = serviceStatuses >>= putStr . statusText

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
  -- history lives under ~/.trha/state/ (a legacy ~/.trha/history is copied
  -- once by historyFilePath, so old entries survive the move)
  histFile <- historyFilePath
  customCmds <- loadCustomCommands
  let baseSettings = defaultSettings :: Settings IO
      settings = baseSettings
        { historyFile = Just histFile
        , autoAddHistory = True
        , complete = completeSlash
        }
  runInputT settings (loop customCmds)
  where
    loop :: [CustomCommand] -> InputT IO ()
    loop cmds = do
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
          let command = parseCommandWith (map ccName cmds) (T.pack input)
          case command of
            Quit -> liftIO $ putStrLn (T.unpack (tr lang "Goodbye!"))
            StopConfirmed -> do
              rs <- liftIO (stopAll False)
              liftIO $ mapM_ (putStrLn . uncurry stopResultText) rs
              liftIO $ putStrLn (T.unpack (tr lang "Stopped. Goodbye!"))
            _ -> do
              result <- liftIO $ executeCommand lang bridge sessionRef modelRef command
              case result of
                Just msg -> liftIO $ putStrLn (T.unpack msg)
                Nothing -> return ()
              loop cmds

-- | @trha fonts …@
runFontsMode :: Text -> IO ()
runFontsMode act = case T.toLower (T.strip act) of
  "status"   -> mapM_ TIO.putStrLn =<< fontsStatus
  "activate" -> fontsActivate >>= either TIO.putStrLn TIO.putStrLn
  "tty"      -> mapM_ TIO.putStrLn =<< fontsTty
  _          -> putStrLn "usage: trha fonts [status|activate|tty]"

-- | @trha setup [--yes]@ — one-time initialisation of the user data
-- directory.
--
-- With a terminal it runs the questionnaire in "UI.SetupWizard"; with
-- @--yes@ (or a piped stdin) it only creates the skeleton and keeps the
-- current settings.
runSetupMode :: Bool -> CLIConfig -> IO ()
runSetupMode nonInteractive config = do
  let lang = parseLang (configLang config)
  _ <- runSetupWizard lang nonInteractive config
  pure ()

-- | Main entry point
main :: IO ()
main = do
#if defined(mingw32_HOST_OS)
  -- 默认代码页是 936(GBK)，UTF-8 的中文会被显示成乱码，先切到 65001。
  _ <- c_SetConsoleOutputCP 65001
#endif
  -- Windows 控制台编码兜底：无论 chcp/终端如何，程序内部一律按 UTF-8
  -- 处理输出与文件路径。cabal run 的输出转发层按 locale 转码是显示乱码
  -- 的另一层——遇到乱码优先直接跑 exe 绕过转发层。
  hSetEncoding stdout utf8
  hSetEncoding stderr utf8
  setLocaleEncoding utf8
  (opts, mcmd) <- execParser cliParserInfo
  config <- buildConfig opts
  case resolveCommand mcmd of
    CmdTUI   -> runTUIMode config
    CmdCLI   -> runCLIMode config
    CmdServe kernelPort stateDir -> runServeMode kernelPort stateDir config
    CmdSetup nonInteractive -> runSetupMode nonInteractive config
    CmdSettingsSchema -> putStrLn (T.unpack settingsSchemaJson)
    CmdFonts act -> runFontsMode act
    CmdStop svc force -> runStopMode svc force
    CmdStatus -> runStatusMode
    CmdSandbox action -> runSandboxCommand action
