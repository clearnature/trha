{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | 模型与供应商命令：模型列表/切换、供应商列表、effort、上下文窗口，
-- 以及模型预设与收藏。
--
-- 领域模块之一（约定见 "UI.Commands.Env"）。
module UI.Commands.Model
  ( runModel
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
import UI.Commands.Env (CmdEnv(..))
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

runModel :: CmdEnv -> Command -> Maybe (IO (Maybe Text))
runModel env = go
  where
    lang       = ceLang env
    bridge     = ceBridge env
    sessionRef = ceSession env
    modelRef   = ceModel env

    go Models = Just $ do
      result <- listModels bridge
      return $ Just $ case result of
        Right models -> if null models
          then tr lang "No models available"
          else (tr lang "Models:" <> "\n") <> T.unlines (map (\m -> "  - " <> modelName m <> " (" <> modelDescription m <> ")") models)
        Left err -> tr lang "Error: " <> T.pack (show err)

    go (SelectModel name) = Just $ do
      writeIORef modelRef name
      return $ Just $ tr lang "Model selected: " <> name

    go ShowModel = Just $ do
      model <- readIORef modelRef
      return $ Just $ tr lang "Current model: " <> model

    go (Fav arg) = Just $ do
      m <- readIORef modelRef
      p <- loadModelPrefs
      let name = if T.null (T.strip arg) then m else T.strip arg
          p' = toggleFavorite name p
      saveModelPrefs p'
      return $ Just ("favourite: " <> name)

    go (SetCtx arg) = Just $ do
      cfg <- resolveConfig defaultCLIConfig
      let raw = T.strip arg
      if T.null raw
        then return $ Just ("context: " <> maybe "model default" (T.pack . show) (configCtxSize cfg))
        else case reads (T.unpack raw) :: [(Int, String)] of
          [(n, "")] | n > 0 -> do
            saveConfig (cfg { configCtxSize = Just n })
            return $ Just ("context: " <> T.pack (show n) <> " tokens")
          _ -> return $ Just ("Usage: /ctx <tokens>")

    go (Effort arg) = Just $ do
      cfg <- resolveConfig defaultCLIConfig
      let lvl = T.toLower (T.strip arg)
          levels = ["auto", "minimal", "low", "medium", "high"]
      if T.null lvl
        then return $ Just ("effort: " <> configEffort cfg
                              <> "  (auto|minimal|low|medium|high)")
        else if lvl `elem` levels
          then do
            saveConfig (cfg { configEffort = lvl })
            return $ Just ("effort: " <> lvl)
          else return $ Just ("Unknown effort: " <> arg
                                <> "  (auto|minimal|low|medium|high)")

    go Providers = Just $ do
      result <- listProviders bridge
      return $ Just $ case result of
        Right [] -> tr lang "No providers configured (see ~/.trha/providers.json)."
        Right ps -> (tr lang "Providers:" <> "\n") <> T.unlines
          [ "  - " <> piName p <> " (" <> piKind p <> ")"
              <> " · " <> piDefault p
              <> (if piInUse p then " · in use" else "")
          | p <- ps ]
          <> tr lang "Switch providers in the TUI (/provider or ctrl+x p)."
        Left err -> tr lang "Error: " <> T.pack (show err)

    go ShowContext = Just $ do
      cfg <- resolveConfig defaultCLIConfig
      return $ Just $ tr lang "Context window: "
        <> maybe (tr lang "model default") (T.pack . show) (configCtxSize cfg)

    go ShowPresets = Just $
      return $ Just $ T.unlines
        ( tr lang "Provider presets:" :
          [ "  " <> preName p <> " (" <> preKind p <> ") " <> preBaseUrl p | p <- presets ] )

    go (SwitchProvider Nothing) = Just $ do
      r <- listProviders bridge
      return $ Just $ case r of
        Left e -> tr lang "Error: " <> T.pack (show e)
        Right [] -> tr lang "No providers configured."
        Right ps -> T.unlines
          (tr lang "Providers:" :
            [ "  " <> (if piInUse p then "* " else "  ") <> piName p <> " (" <> piKind p <> ")"
            | p <- ps ])

    go (SwitchProvider (Just name)) = Just $ do
      r <- setInUseProvider bridge (T.strip name)
      return $ Just $ case r of
        Left e -> tr lang "Error: " <> T.pack (show e)
        Right _ -> tr lang "Switched to " <> T.strip name

    go _ = Nothing
