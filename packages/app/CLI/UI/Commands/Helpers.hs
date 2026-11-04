{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | 命令层共享的纯辅助：被多个领域模块（Plan/Session/Tools）用到，
-- 又不能放进其中任何一个（否则 import 成环）。
module UI.Commands.Helpers
  ( parseInterval
  , snapshotBase
  , findFilesNamed
  , pricesFromEnv
  , toCardStatus
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
import UI.I18n (Lang(..), langName, parseLang, tr)
import Config.Settings (resolveConfig, saveConfig)

parseInterval :: Text -> Maybe Int
parseInterval raw = case T.unsnoc (T.toLower (T.strip raw)) of
  Just (num, 's') -> (* 1000) <$> readInt num
  Just (num, 'm') -> (* 60000) <$> readInt num
  Just (num, 'h') -> (* 3600000) <$> readInt num
  _               -> readInt (T.strip raw)
  where
    readInt s = case reads (T.unpack s) :: [(Int, String)] of
      [(n, "")] | n > 0 -> Just n
      _                 -> Nothing

snapshotBase :: FilePath -> Maybe FilePath
snapshotBase name =
  let parts = T.splitOn "-" (T.pack name)
      isDigest p = T.length p == 8 && T.all isHexDigit p
  in case break isDigest parts of
       (_, _ : rest@(_ : _)) -> Just (T.unpack (T.intercalate "-" rest))
       _ -> Nothing

findFilesNamed :: FilePath -> FilePath -> IO [FilePath]
findFilesNamed root name = go root (0 :: Int)
  where
    skip = [".git", "node_modules", "dist-newstyle", ".dist-newstyle", "3rdparty", "archive"]
    go d depth
      | depth > 6 = return []
      | otherwise = do
          isDir <- doesDirectoryExist d
          if not isDir
            then return []
            else do
              entries <- listDirectory d
              fmap concat (mapM (visit d depth) entries)
    visit d depth e
      | e == name = return [d </> e]
      | e `elem` skip || take 1 e == "." = return []
      | otherwise = do
          isDir <- doesDirectoryExist (d </> e)
          if isDir then go (d </> e) (depth + 1) else return []

toCardStatus :: ToolRunStatus -> ToolStatus
toCardStatus s = case s of
  ToolRunRunning   -> ToolRunning
  ToolRunSucceeded -> ToolSucceeded
  ToolRunFailed e  -> ToolFailed e

pricesFromEnv :: IO Prices
pricesFromEnv = do
  i <- lookupEnv "TRHA_PRICE_INPUT"
  c <- lookupEnv "TRHA_PRICE_CACHED"
  o <- lookupEnv "TRHA_PRICE_OUTPUT"
  pure (Prices (readD i) (readD c) (readD o))
  where
    readD = maybe 0 (\s -> maybe 0 id (readMaybe s))
