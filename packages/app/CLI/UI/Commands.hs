{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | REPL command executor.  Command types and parsing live in the pure
-- "UI.Commands.Registry" (single source of truth shared with the TUI
-- quick picker and tab completion); this module implements the IO side.
module UI.Commands
  ( -- * Re-exported registry
    module UI.Commands.Registry
    -- * Execution
  , executeCommand
    -- * Shared settings runner (REPL + TUI)
  , runSettingsCommand
    -- * Shared local-shell runner (REPL + TUI)
  , runLocalShell
    -- * Resume candidates (local transcripts ∪ scheduler sessions)
  , resumeSessions
  , resumeMessages
  ) where

import Data.Aeson (Object, Value(..), decode, object, (.=))
import qualified Data.Aeson.Key as AesonKey
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.ByteString.Lazy as BSL
import Data.Char (isHexDigit)
import Core.Types
import Bridge.Scheduler (SchedulerBridge, listPlugins, listSessions, createSession, deleteSession, sendMessage, sendMessageWithUsage, sendMessageWithEffort, listModels, listProviders, planStep, approvePlan, denyPlan, denyPlanWithReason, subscribeSessionEvents, submitPlan, decideStep, fetchPlan, fetchSessionInfo, fetchAgents, renameSession, tagSession, fetchSessionMode, applySessionMode, reportStep, fetchBalance, fetchUsageStats, UsageRow(..), compactSession, retrySession, btwAsk, recapSession, queueMessage, fetchQueue, steerSession, forkSession, branchSession, setSessionCwd, setInUseProvider, startLoop, fetchLoops, stopLoops, listWorkflows, runWorkflow, fetchServiceStatus, probeProvider, listTools, fetchPermissions, getMessages)
import UI.ProviderPresets (presets, preBaseUrl, preKind, preName)
import Core.Currency (CurrencyTable(..), loadCurrency, saveCurrency)
import Core.Replay (ReplayBlock(..), renderReplay, renderReplayText)
import Core.Export (exportMarkdown, exportJson, defaultExportName)
import Core.TurnStats (Prices(..), pricesForModel, turnSummary)
import Core.SessionSummary (SessionSummary(..), pickLocalSession)
import Core.Memory (allMemories, forgetText, rememberText)
import Core.ProjectStore (ProjectSession(..), projectSessions)
import Core.Transcript (listLocalSessions, listLocalSessionsIn, loadTranscript, recordChunk, recordModelRequest, recordSession, recordToolEvent, recordUser)
import Control.Concurrent (threadDelay)
import Control.Exception (IOException, catch, try)
import qualified Data.Map as Map
import Data.IORef
import Data.List (partition, sort)
import Data.Text (Text)
import qualified Data.Text as T
import System.IO (hClose, hFlush, hPutStr, openTempFile, stdout)
import System.Environment (lookupEnv, getEnvironment)
import Data.Maybe (fromMaybe)
import Core.Clipboard (saveClipboardImage)
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist, getHomeDirectory, getTemporaryDirectory, listDirectory, removeFile)
import System.FilePath ((</>))
import System.Exit (ExitCode(..))
import System.Process (readProcessWithExitCode, readCreateProcessWithExitCode, proc, env)
import System.Timeout (timeout)
import qualified Data.Text.IO as TIO
import Data.Time.Clock (getCurrentTime)
import Data.Time.LocalTime (getCurrentTimeZone, utcToZonedTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import System.Directory (createDirectoryIfMissing, getHomeDirectory)
import System.Environment (lookupEnv)
import Text.Read (readMaybe)
import System.FilePath ((</>), takeDirectory)
import System.Process (callCommand)
import UI.Render.ToolCard (ToolStatus(..), toolCardWithStatus)
import UI.Commands.Registry
import UI.Stash (Stash(..), stashPush, stashPop, stashEntries, loadStash, saveStash)
import UI.ModelPrefs (loadModelPrefs, saveModelPrefs, toggleFavorite)
import UI.Skills (Skill(..), scanSkills, skillDirs)
import UI.InputHistory (HistState(..), loadHistory)
import UI.CustomCommands (CustomCommand(..), loadCustomCommands, renderCustomCommand)
import UI.Theme (Theme(..), themes, themeNames, resolveTheme)
import UI.Render.Sidebar (agentTreeLines)
import System.Directory (getCurrentDirectory)
import UI.Commands.Env (CmdEnv(..), dispatch)
import UI.Commands.Meta (runMeta)
import UI.Commands.Config (runConfig, runSettingsCommand)
import UI.Commands.Integration (runIntegration)
import UI.Commands.Model (runModel)
import UI.Commands.Plan (approvePlanStep, decidePlanStep, runPlan)
import UI.Commands.Tools (gitCount, jsonMaybeStr, jsonStr, readProviderKey, runLocalShell, runTools)
import UI.Commands.Session (friendlyDenyError, resumeMessages, resumeSessions, runSession)
import UI.I18n (Lang(..), langName, parseLang, tr)
import Config.Settings (resolveConfig, saveConfig)

-- | Handle @/settings@ outside the interactive loop: read the effective
-- configuration, then either print it or apply+persist one key.  Shared by
-- the REPL executor and the TUI so both surfaces behave identically.

executeCommand :: Lang -> SchedulerBridge -> IORef (Maybe SessionId) -> IORef Text -> Command -> IO (Maybe Text)
-- | Parse a loop interval: @30s@, @5m@, @1h@, or plain seconds.

executeCommand lang bridge sessionRef modelRef cmd
  | Just act <- dispatch [runMeta, runModel, runSession, runConfig, runIntegration, runTools, runPlan] env cmd = act
  where env = CmdEnv lang bridge sessionRef modelRef


executeCommand lang bridge sessionRef _ (DeleteSession sid) = do
  if null sid
    then return $ Just (tr lang "Usage: /delete <session-id>")
    else do
      result <- deleteSession bridge sid
      current <- readIORef sessionRef
      case current of
        Just currentSid | currentSid == sid -> writeIORef sessionRef Nothing
        _ -> return ()
      return $ Just $ case result of
        Right () -> tr lang "Session deleted: " <> T.pack sid
        Left err -> tr lang "Error: " <> T.pack (show err)

executeCommand lang _ sessionRef modelRef Status = do
  session <- readIORef sessionRef
  model <- readIORef modelRef
  return $ Just $ T.unlines
    [ tr lang "Status:"
    , tr lang "  Current session: " <> maybe (tr lang "none") T.pack session
    , tr lang "  Current model: " <> model
    ]

executeCommand lang bridge _ _ Doctor = do
  sessions <- listSessions bridge
  providers <- listProviders bridge
  cfg <- resolveConfig defaultCLIConfig
  font <- try (readProcessWithExitCode "fc-match" ["-f", "%{file}", ":lang=zh-Hans"] "")
            :: IO (Either IOException (ExitCode, String, String))
  let fontLine = case font of
        Right (_, out, _) -> T.strip (T.pack out)
        Left _ -> tr lang "fontconfig unavailable"
  return $ Just $ T.unlines
    [ tr lang "Doctor:"
    , tr lang "  scheduler: " <> either (const (tr lang "unreachable")) (const (tr lang "ok")) sessions
    , tr lang "  providers: " <> either (const (tr lang "unreachable")) (T.pack . show . length) providers
    , tr lang "  language: " <> langName lang
    , tr lang "  context: " <> maybe (tr lang "model default") (T.pack . show) (configCtxSize cfg)
    , tr lang "  font: " <> fontLine
    ]

executeCommand lang bridge _ _ (SwitchProvider Nothing) = do
  r <- listProviders bridge
  return $ Just $ case r of
    Left e -> tr lang "Error: " <> T.pack (show e)
    Right [] -> tr lang "No providers configured."
    Right ps -> T.unlines
      (tr lang "Providers:" :
        [ "  " <> (if piInUse p then "* " else "  ") <> piName p <> " (" <> piKind p <> ")"
        | p <- ps ])

executeCommand lang bridge _ _ (SwitchProvider (Just name)) = do
  r <- setInUseProvider bridge (T.strip name)
  return $ Just $ case r of
    Left e -> tr lang "Error: " <> T.pack (show e)
    Right _ -> tr lang "Switched to " <> T.strip name

executeCommand lang bridge _ _ (Auth arg) = do
  ps <- listProviders bridge
  case ps of
    Left e -> return $ Just (tr lang "Error: " <> T.pack (show e))
    Right infos -> case T.words arg of
      [] -> return $ Just $ T.unlines
        (tr lang "Providers:"
         : [ "  - " <> piName p <> " (" <> piKind p <> ")"
             <> (if piHasKey p then " · key saved" else " · no key")
             <> (if piInUse p then " · in use" else "")
           | p <- infos ])
      ("check" : name : _) -> case [ p | p <- infos, piName p == name ] of
        [] -> return $ Just (tr lang "Unknown provider: " <> name)
        (p : _) -> do
          mkey <- readProviderKey (piName p)
          case mkey of
            Nothing -> return $ Just $ tr lang "No key saved for " <> name
            Just key -> do
              r <- probeProvider bridge (piBaseUrl p) key
              return $ Just $ case r of
                Left e -> tr lang "Probe failed: " <> T.pack (show e)
                Right probed -> tr lang "Probe ok: " <> T.pack (show probed)
      _ -> return $ Just (tr lang "Usage: /auth [check <name>]")

-- | @/update@：本地源码部署下和 origin/main 比对；@/update pull@ 快进。
executeCommand lang _ _ _ (Update arg) = do
  cwd <- getCurrentDirectory
  let git xs = readCreateProcessWithExitCode (proc "git" ("-C" : cwd : xs)) ""
  top <- git ["rev-parse", "--show-toplevel"]
  case top of
    (ExitFailure _, _, _) -> return $ Just $ tr lang "Not a git checkout: " <> T.pack cwd
    _ -> do
      fetched <- timeout 60000000 (git ["fetch", "--quiet", "origin"])
      case fetched of
        Nothing -> return $ Just (tr lang "git fetch timed out.")
        Just (ExitFailure _, _, err) ->
          return $ Just $ tr lang "git fetch failed: " <> T.pack (take 300 err)
        Just _ -> case T.strip arg of
          "pull" -> do
            pulled <- git ["pull", "--ff-only", "origin", "main"]
            return $ Just $ case pulled of
              (ExitSuccess, out, _) -> tr lang "Updated:\n" <> T.pack out
              (ExitFailure _, _, err) -> tr lang "Pull failed: " <> T.pack err
          _ -> do
            behind <- git ["rev-list", "--count", "HEAD..origin/main"]
            ahead  <- git ["rev-list", "--count", "origin/main..HEAD"]
            return $ Just $ T.unlines
              [ tr lang "Behind origin/main: " <> gitCount behind
              , tr lang "Ahead of origin/main: " <> gitCount ahead
              , tr lang "Run /update pull to fast-forward." ]

-- | @/cd <path>@：切换会话工作目录（与 /workspace 同一条后端路径）。
executeCommand lang _ _ _ (SetLanguage Nothing) =
  return $ Just $ tr lang "Current language: " <> langName lang
    <> tr lang " — use /language <code> (available: "
    <> T.intercalate ", " (map langName ([minBound .. maxBound] :: [Lang]))
    <> ")"

executeCommand lang _ _ _ (SetLanguage (Just code)) = do
  cfg <- resolveConfig defaultCLIConfig
  let l = parseLang code
  saveConfig (cfg { configLang = langName l })
  return $ Just (tr l "Language: " <> langName l)

executeCommand _ _ _ _ cmd =
  return $ Just ("Command not available in this front-end: " <> T.pack (show cmd))

-- | 快照文件名 @&lt;stamp&gt;-&lt;sha1前8位&gt;-&lt;basename&gt;@ 里取 basename。
-- stamp 自己也含 @-@，所以按「第一个 8 位十六进制段」定位分隔点。

-- | 在 root 下按文件名找文件（跳过 .git/依赖目录，深度上限 6）。

-- | 从 @~/.trha/provider-keys.json@ 读一个 provider 的 key（只在本机进程内用）。

-- | @git rev-list --count@ 的输出。

-- | 可恢复会话 = 本地 transcript ∪ 调度层（stateDir 恢复的）会话。
--
-- 本地有的带标题与轮次；只在调度层存在的补一条最小摘要——它没有本地
-- transcript，历史由 'resumeMessages' 从调度层拉回来。

-- | 取 JSON 对象的可选字符串字段。
