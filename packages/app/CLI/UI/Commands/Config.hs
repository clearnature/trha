{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | 界面与运行时配置命令：主题、语言、推理语言、输出风格、权限模式、
-- 沙箱、审批超时、货币、鼠标捕获、单项设置与设置面板。
--
-- 领域模块之一（约定见 "UI.Commands.Env"）。
module UI.Commands.Config
  ( runConfig
  , runSettingsCommand
  ) where

import Data.Aeson (Object, Value(..), decode, object, (.=))
import qualified Data.Aeson.Key as AesonKey
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.ByteString.Lazy as BSL
import Core.Types
import Bridge.Scheduler (SchedulerBridge, listPlugins, listSessions, createSession, deleteSession, sendMessage, sendMessageWithUsage, sendMessageWithEffort, listModels, listProviders, planStep, approvePlan, denyPlan, denyPlanWithReason, subscribeSessionEvents, submitPlan, decideStep, fetchPlan, fetchSessionInfo, fetchAgents, renameSession, tagSession, fetchSessionMode, applySessionMode, reportStep, fetchBalance, fetchUsageStats, UsageRow(..), compactSession, retrySession, btwAsk, recapSession, queueMessage, fetchQueue, steerSession, forkSession, branchSession, setSessionCwd, setInUseProvider, startLoop, fetchLoops, stopLoops, listWorkflows, runWorkflow, fetchServiceStatus, probeProvider, listTools, fetchPermissions, getMessages)
import Core.Currency (CurrencyTable(..), loadCurrency, saveCurrency)
import Core.Replay (ReplayBlock(..), renderReplay, renderReplayText)
import Core.TurnStats (Prices(..), pricesForModel, turnSummary)
import Core.SessionSummary (SessionSummary(..), pickLocalSession)
import Core.ProjectStore (ProjectSession(..), projectSessions)
import qualified Data.Map as Map
import Data.IORef
import Data.Text (Text)
import qualified Data.Text as T
import System.IO (hFlush, hPutStr, stdout)
import System.Environment (lookupEnv)
import Data.Maybe (fromMaybe)
import System.FilePath ((</>))
import System.Exit (ExitCode(..))
import System.Process (env)
import System.Timeout (timeout)
import qualified Data.Text.IO as TIO
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import System.Environment (lookupEnv)
import System.FilePath ((</>), takeDirectory)
import UI.Render.ToolCard (ToolStatus(..), toolCardWithStatus)
import UI.Commands.Env (CmdEnv(..))
import UI.Commands.Registry
import UI.Stash (Stash(..), stashPush, stashPop, stashEntries, loadStash, saveStash)
import UI.Skills (Skill(..), scanSkills, skillDirs)
import UI.InputHistory (HistState(..), loadHistory)
import UI.CustomCommands (CustomCommand(..), loadCustomCommands, renderCustomCommand)
import UI.Theme (Theme(..), themes, themeNames, resolveTheme)
import UI.I18n (Lang(..), langName, parseLang, tr)
import Config.Settings (resolveConfig, saveConfig)

runConfig :: CmdEnv -> Command -> Maybe (IO (Maybe Text))
runConfig env = go
  where
    lang       = ceLang env
    bridge     = ceBridge env
    sessionRef = ceSession env
    modelRef   = ceModel env

    go (SetMouseCapture arg) = Just $ do
      cfg <- resolveConfig defaultCLIConfig
      case arg of
        Nothing -> return $ Just ("Mouse capture: "
          <> (if configMouseCapture cfg then "on" else "off (native terminal selection)")
          <> " — /mouse on|off")
        Just on -> do
          saveConfig (cfg { configMouseCapture = on })
          -- xterm SGR mouse reporting: off restores native terminal selection.
          hPutStr stdout (if on
            then "\ESC[?1000h\ESC[?1002h\ESC[?1006h"
            else "\ESC[?1000l\ESC[?1002l\ESC[?1003l\ESC[?1006l")
          hFlush stdout
          return $ Just (if on
            then "Mouse capture: on"
            else "Mouse capture: off — the terminal now does text selection")

    go (SetTheme arg) = Just $ do
      cfg <- resolveConfig defaultCLIConfig
      let name = T.strip arg
      if T.null name
        then return $ Just ("Themes: " <> T.intercalate ", " themeNames)
        else do
          let th = resolveTheme name
          if T.toLower (themeName th) /= T.toLower name
            then return $ Just ("Unknown theme: " <> name)
            else do
              saveConfig (cfg { configTheme = themeName th })
              return $ Just ("theme: " <> themeName th)

    go (Mode arg) = Just $ do
      msid <- readIORef sessionRef
      case msid of
        Nothing -> return $ Just (tr lang "No active session.")
        Just sid -> do
          let name = T.strip arg
              body = if T.null name
                       then object ["action" .= ("cycle" :: Text)]
                       else object ["action" .= ("set" :: Text), "mode" .= name]
          r <- applySessionMode bridge sid body
          return $ Just $ case r of
            Right m  -> tr lang "Mode: " <> smLabel m
            Left e   -> T.pack (show e)

    go Verbose = Just $
      return $ Just "Verbose is available in the TUI (/verbose)"

    go ShowSettings = Just $ runSettingsCommand lang ""

    go (AskTimeout arg) = Just $ do
      cfg <- resolveConfig defaultCLIConfig
      case arg of
        Nothing -> return $ Just $ tr lang "Approval timeout: "
          <> T.pack (show (configAskTimeout cfg)) <> tr lang " seconds"
        Just raw -> case reads (T.unpack (T.strip raw)) :: [(Int, String)] of
          [(n, "")] | n > 0 -> do
            saveConfig (cfg { configAskTimeout = n })
            return $ Just $ tr lang "Approval timeout: " <> T.pack (show n) <> tr lang " seconds"
          _ -> return $ Just (tr lang "Usage: /ask-timeout <seconds>")

    go (ReasoningLanguage arg) = Just $ do
      cfg <- resolveConfig defaultCLIConfig
      case arg of
        Nothing -> return $ Just $ tr lang "Reasoning language: " <> configReasoningLanguage cfg
        Just code -> do
          let v = T.strip code
              low = T.toLower v
          if low `elem` ["auto", "zh-hans", "zh-hant", "en", "fr", "es", "ru", "th", "my", "bo", "ii"]
            then do
              saveConfig (cfg { configReasoningLanguage = low })
              return $ Just $ tr lang "Reasoning language: " <> low
            else return $ Just $ tr lang "Usage: /reasoning-language [auto|zh-Hans|zh-Hant|en]"

    go (Currency arg) = Just $ do
      now <- getCurrentTime
      let ts = T.pack (formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" now)
      table <- loadCurrency
      let usage = tr lang "Usage: /currency set <CODE> <rate> | /currency base <CODE>"
      case T.words (T.strip arg) of
        [] -> return $ Just $ T.unlines $
          [ tr lang "Currency (base " <> ctBase table <> "):"
          , "  updatedAt: " <> fromMaybe (tr lang "never") (ctUpdatedAt table)
          ] ++ [ "  " <> k <> "  " <> T.pack (show v) | (k, v) <- Map.toList (ctRates table) ]
        ["set", code, rate] -> case reads (T.unpack rate) :: [(Double, String)] of
          [(v, "")] | v > 0 -> do
            let table' = table
                  { ctRates = Map.insert (T.toUpper code) v (ctRates table)
                  , ctUpdatedAt = Just ts }
            saveCurrency table'
            return $ Just $ tr lang "Currency updated: " <> T.toUpper code
              <> " = " <> T.pack (show v)
          _ -> return $ Just usage
        ["base", code] -> do
          let table' = table { ctBase = T.toUpper code, ctUpdatedAt = Just ts }
          saveCurrency table'
          return $ Just $ tr lang "Currency base: " <> T.toUpper code
        _ -> return $ Just usage

    go (OutputStyle arg) = Just $ do
      cfg <- resolveConfig defaultCLIConfig
      case arg of
        Nothing -> return $ Just $ tr lang "Output style: " <> configOutputStyle cfg
        Just name ->
          let v = T.toLower (T.strip name)
          in if v `elem` ["default", "concise", "detailed"]
               then do
                 saveConfig (cfg { configOutputStyle = v })
                 return $ Just $ tr lang "Output style: " <> v
               else return $ Just $ tr lang "Usage: /output-style [default|concise|detailed]"

    go (SetSetting "" _) = Just $
      return $ Just (tr lang "Usage: /settings <key> <value>")

    go (SetSetting key raw)
      | T.null key || T.null (T.strip raw) = Just $
          return $ Just (tr lang "Usage: /settings <key> <value>")
      | otherwise = Just $ runSettingsCommand lang (key <> " " <> raw)

    go Sandbox = Just $ do
      enabled <- lookupEnv "TRHA_SANDBOX"
      let state = case fmap (T.toLower . T.strip . T.pack) enabled of
            Just v | v `elem` ["on", "1", "true", "enforce"] -> "on"
            _ -> "off"
      let label = if state == "on" then "enabled" else "disabled"
      return $ Just ("SandBox: " <> label
        <> " (TUI: /sandbox opens the panel; the scheduler reads TRHA_SANDBOX)")

    go (SetLanguage Nothing) = Just $
      return $ Just $ tr lang "Current language: " <> langName lang
        <> tr lang " — use /language <code> (available: "
        <> T.intercalate ", " (map langName ([minBound .. maxBound] :: [Lang]))
        <> ")"

    go (SetLanguage (Just code)) = Just $ do
      cfg <- resolveConfig defaultCLIConfig
      let l = parseLang code
      saveConfig (cfg { configLang = langName l })
      return $ Just (tr l "Language: " <> langName l)

    go _ = Nothing

runSettingsCommand :: Lang -> Text -> IO (Maybe Text)
runSettingsCommand lang arg =
  case T.words arg of
    [] -> do
      cfg <- resolveConfig defaultCLIConfig
      return $ Just (formatSettings lang cfg)
    (key : rest) -> do
      cfg <- resolveConfig defaultCLIConfig
      let raw = T.unwords rest
      case parseSettingValue lang cfg key raw of
        Left err    -> return $ Just err
        Right newCfg -> do
          saveConfig newCfg
          return $ Just (tr lang "Setting updated: " <> key)

-- | Execute a command
-- | Run one local shell command, shared by the REPL (@/shell@) and the TUI
-- card renderer (@UI.Brick@).
--
-- A native Windows console has no @bash@, so @ComSpec@ runs the command via
-- @/c@; everywhere else uses @bash -lc@.  The dsh/Codex ENV_OVERRIDES keep
-- colour, pagers and interactive features from garbling captured output.  The
-- run is capped at 120 s so a hung command cannot wedge the shell.
