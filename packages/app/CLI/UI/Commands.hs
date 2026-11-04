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
import UI.Commands.Integration (runIntegration)
import UI.Commands.Plan (approvePlanStep, decidePlanStep, runPlan)
import UI.Commands.Session (friendlyDenyError, resumeMessages, resumeSessions, runSession)
import UI.I18n (Lang(..), langName, parseLang, tr)
import Config.Settings (resolveConfig, saveConfig)

-- | Handle @/settings@ outside the interactive loop: read the effective
-- configuration, then either print it or apply+persist one key.  Shared by
-- the REPL executor and the TUI so both surfaces behave identically.
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
runLocalShell :: Text -> IO (Either Text (ExitCode, String, String))
runLocalShell cmd = do
  r <- timeout 120000000 $ do
    mSpec <- lookupEnv "ComSpec"
    let (sh, shArgs) = case mSpec of
          Just spec -> (spec, ["/c", T.unpack cmd])
          Nothing   -> ("bash", ["-lc", T.unpack cmd])
    baseEnv <- getEnvironment
    let overrides = [("NO_COLOR", "1"), ("TERM", "dumb")
                    , ("PAGER", "cat"), ("GIT_PAGER", "cat")]
        childEnv  = [kv | kv <- baseEnv
                    , fst kv `notElem` map fst overrides] ++ overrides
        cp = (proc sh shArgs) { env = Just childEnv }
    try (readCreateProcessWithExitCode cp "")
      :: IO (Either IOException (ExitCode, String, String))
  return $ case r of
    Nothing         -> Left "shell: timed out after 120s"
    Just (Left e)   -> Left ("shell: " <> T.pack (show e))
    Just (Right ok) -> Right ok

executeCommand :: Lang -> SchedulerBridge -> IORef (Maybe SessionId) -> IORef Text -> Command -> IO (Maybe Text)
-- | Parse a loop interval: @30s@, @5m@, @1h@, or plain seconds.

executeCommand lang bridge sessionRef modelRef cmd
  | Just act <- dispatch [runMeta, runSession, runIntegration, runPlan] env cmd = act
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

executeCommand lang bridge _ _ Models = do
  result <- listModels bridge
  return $ Just $ case result of
    Right models -> if null models
      then tr lang "No models available"
      else (tr lang "Models:" <> "\n") <> T.unlines (map (\m -> "  - " <> modelName m <> " (" <> modelDescription m <> ")") models)
    Left err -> tr lang "Error: " <> T.pack (show err)

executeCommand lang _ _ modelRef (SelectModel name) = do
  writeIORef modelRef name
  return $ Just $ tr lang "Model selected: " <> name

executeCommand lang _ _ modelRef ShowModel = do
  model <- readIORef modelRef
  return $ Just $ tr lang "Current model: " <> model

executeCommand lang _ sessionRef modelRef Status = do
  session <- readIORef sessionRef
  model <- readIORef modelRef
  return $ Just $ T.unlines
    [ tr lang "Status:"
    , tr lang "  Current session: " <> maybe (tr lang "none") T.pack session
    , tr lang "  Current model: " <> model
    ]

executeCommand _ _ _ modelRef (Fav arg) = do
  m <- readIORef modelRef
  p <- loadModelPrefs
  let name = if T.null (T.strip arg) then m else T.strip arg
      p' = toggleFavorite name p
  saveModelPrefs p'
  return $ Just ("favourite: " <> name)

executeCommand _ _ _ _ (SetCtx arg) = do
  cfg <- resolveConfig defaultCLIConfig
  let raw = T.strip arg
  if T.null raw
    then return $ Just ("context: " <> maybe "model default" (T.pack . show) (configCtxSize cfg))
    else case reads (T.unpack raw) :: [(Int, String)] of
      [(n, "")] | n > 0 -> do
        saveConfig (cfg { configCtxSize = Just n })
        return $ Just ("context: " <> T.pack (show n) <> " tokens")
      _ -> return $ Just ("Usage: /ctx <tokens>")

executeCommand _ _ _ _ (Effort arg) = do
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

executeCommand _ _ _ _ (SetMouseCapture arg) = do
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

executeCommand _ _ _ _ (SetTheme arg) = do
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

executeCommand lang bridge sessionRef _ (Mode arg) = do
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

executeCommand _ _ _ _ (RunShell cmd)
  | T.null (T.strip cmd) = return $ Just "Usage: /shell <cmd>"
  | otherwise = do
      r <- runLocalShell cmd
      return $ Just $ case r of
        Left e -> e
        Right (code, out, err) ->
          let body   = T.take 20000 (T.pack (out <> err))
              suffix = case code of
                ExitSuccess   -> ""
                ExitFailure n -> "\n(exit " <> T.pack (show n) <> ")"
          in "$ " <> cmd <> "\n" <> body <> suffix

executeCommand _ _ _ _ CopyLast =
  return $ Just "Copy is available in the TUI (run: trha tui, then /copy)"

executeCommand _ _ _ _ Verbose =
  return $ Just "Verbose is available in the TUI (/verbose)"

executeCommand lang _ _ _ ShowSettings = runSettingsCommand lang ""

executeCommand lang bridge _ _ Providers = do
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

executeCommand lang _ _ _ ShowDiff = do
  r <- try (readProcessWithExitCode "git" ["diff", "--no-color"] "")
         :: IO (Either IOException (ExitCode, String, String))
  return $ Just $ case r of
    Left e -> tr lang "git not available: " <> T.pack (show e)
    Right (_, out, _)
      | null (dropWhile (== '\n') out) -> tr lang "No uncommitted changes."
      | otherwise -> T.take 4000 (T.pack out)

executeCommand lang _ _ _ ShowContext = do
  cfg <- resolveConfig defaultCLIConfig
  return $ Just $ tr lang "Context window: "
    <> maybe (tr lang "model default") (T.pack . show) (configCtxSize cfg)

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

executeCommand lang bridge sessionRef _ ShowStats = do
  rows <- fetchUsageStats bridge
  cur <- readIORef sessionRef
  home <- getHomeDirectory
  transcript <- case cur of
    Nothing -> pure []
    Just sid -> do
      let p = home </> ".trha" </> "sessions" </> sid </> "transcript.jsonl"
      ok <- doesFileExist p
      if not ok
        then pure []
        else do
          content <- TIO.readFile p
          pure [tr lang "  transcript lines: " <> T.pack (show (length (T.lines content)))]
  pure $ Just $ T.unlines $ case rows of
    Left err -> [tr lang "Failed to read usage stats: " <> T.pack (show err)] <> transcript
    Right [] -> [tr lang "No usage recorded yet."] <> transcript
    Right rs ->
      ( tr lang "Usage per session mode (hit% = cache hit / (hit + miss), same split the invoice uses):"
        : ("mode" `pad` 10 <> "requests" `pad` 9 <> "prompt" `pad` 14
             <> "hit%" `pad` 8 <> "out" `pad` 10 <> "resets" `pad` 8 <> "cost")
        : map fmtRow rs
      ) <> transcript
  where
    pad t n = T.justifyLeft n ' ' t
    fmtRow r = pad (urMode r) 10
      <> pad (T.pack (show (urRequests r))) 9
      <> pad (T.pack (show (urPrompt r))) 14
      <> pad (pct (urHitRatio r)) 8
      <> pad (T.pack (show (urCompletion r))) 10
      <> pad (T.pack (show (urResets r))) 8
      <> costText r
    pct ratio = T.pack (show (fromIntegral (round (ratio * 10000) :: Int) / 100 :: Double)) <> "%"
    -- The scheduler only prices a row when TRHA_PRICE_* is configured. Fall
    -- back to the built-in DeepSeek table and mark it as an estimate (≈), so a
    -- missing env var never makes the number look authoritative.
    costText r
      | urCost r == "—" || T.null (urCost r) = "≈¥" <> money (estimateCost r)
      | otherwise = "¥" <> urCost r
    estimateCost r =
      let p = pricesForModel "deepseek"
      in ( fromIntegral (urCacheMiss r) * priceInput p
           + fromIntegral (urCacheHit r) * priceCached p
           + fromIntegral (urCompletion r) * priceOutput p ) / 1e6
    money x = T.pack (show (fromIntegral (round (x * 10000) :: Int) / 10000 :: Double))

executeCommand lang _ _ _ (AskTimeout arg) = do
  cfg <- resolveConfig defaultCLIConfig
  case arg of
    Nothing -> return $ Just $ tr lang "Approval timeout: "
      <> T.pack (show (configAskTimeout cfg)) <> tr lang " seconds"
    Just raw -> case reads (T.unpack (T.strip raw)) :: [(Int, String)] of
      [(n, "")] | n > 0 -> do
        saveConfig (cfg { configAskTimeout = n })
        return $ Just $ tr lang "Approval timeout: " <> T.pack (show n) <> tr lang " seconds"
      _ -> return $ Just (tr lang "Usage: /ask-timeout <seconds>")

executeCommand lang _ _ _ (ReasoningLanguage arg) = do
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

executeCommand lang _ _ _ (Currency arg) = do
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
executeCommand lang bridge sessionRef modelRef (ChangeDir dir)
  | T.null (T.strip dir) = return $ Just (tr lang "Usage: /cd <path>")
  | otherwise = executeCommand lang bridge sessionRef modelRef (Workspace (Just (T.strip dir)))

-- | @/tools [mode]@：列出调度器的工具目录。
executeCommand lang bridge _ _ (ShowTools arg) = do
  let mmode = case T.words arg of
        (m : _) -> Just m
        _       -> Nothing
  r <- listTools bridge mmode
  return $ Just $ case r of
    Left e -> tr lang "Error: " <> T.pack (show e)
    Right defs
      | null defs -> tr lang "No tools registered."
      | otherwise -> T.unlines (tr lang "Tools:" : map renderTool defs)
  where
    renderTool (Object o) =
      "  - " <> jsonStr "name" o
        <> maybe "" (\d -> " — " <> d) (jsonMaybeStr "description" o)
    renderTool v = "  - " <> T.pack (show v)

-- | @/permissions@：权限规则的只读视图。
executeCommand lang bridge _ _ ShowPermissions = do
  r <- fetchPermissions bridge
  return $ Just $ case r of
    Left e -> tr lang "Error: " <> T.pack (show e)
    Right rules
      | null rules -> tr lang "No permission rules."
      | otherwise -> T.unlines (tr lang "Permission rules:" : map renderRule rules)
  where
    renderRule (Object o) = "  - " <> jsonStr "kind" o <> ": " <> jsonStr "pattern" o
    renderRule v = "  - " <> T.pack (show v)

-- | @/history@：最近的输入历史（与 TUI 共用 @~/.trha/history@）。
executeCommand lang _ _ _ ShowHistory = do
  hs <- loadHistory
  let entries = take 20 (hsHistory hs)
  return $ Just $ if null entries
    then tr lang "No input history yet."
    else T.unlines (tr lang "Recent input:" : map ("  " <>) entries)

-- | @/about@：版本、工作区与运行时信息。
-- | @/forget <text>@：删除匹配的备注。
executeCommand lang bridge sessionRef _ (Workspace mdir) = do
  cur <- readIORef sessionRef
  case cur of
    Nothing -> return $ Just (tr lang "No active session.")
    Just sid -> case mdir of
      Nothing -> return $ Just (tr lang "Usage: /workspace <absolute-path>")
      Just dir -> do
        r <- setSessionCwd bridge sid (T.unpack (T.strip dir))
        return $ Just $ case r of
          Left e  -> tr lang "Error: " <> T.pack (show e)
          Right p -> tr lang "Workspace: " <> T.pack p

executeCommand lang _ _ _ (Paste text) = do
  r <- saveClipboardImage
  return $ Just $ case r of
    Nothing -> tr lang "No image in clipboard"
    Just path -> tr lang "Image saved: " <> T.pack path
      <> (if T.null (T.strip text) then "" else " (" <> T.strip text <> ")")

executeCommand lang _ _ _ (OutputStyle arg) = do
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

executeCommand lang _ _ _ ShowPresets =
  return $ Just $ T.unlines
    ( tr lang "Provider presets:" :
      [ "  " <> preName p <> " (" <> preKind p <> ") " <> preBaseUrl p | p <- presets ] )

executeCommand lang bridge _ _ ShowUsage = do
  bal <- fetchBalance bridge
  cfg <- resolveConfig defaultCLIConfig
  return $ Just $ T.unlines
    [ tr lang "Usage:"
    , tr lang "  model: " <> configModel cfg
    , tr lang "  balance: " <> either (const (tr lang "unavailable"))
        (\b -> balanceCurrency b <> " " <> T.pack (show (balanceTotal b))) bal
    ]

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

executeCommand lang _ _ _ (SetSetting "" _) =
  return $ Just (tr lang "Usage: /settings <key> <value>")

executeCommand lang _ _ _ (SetSetting key raw)
  | T.null key || T.null (T.strip raw) =
      return $ Just (tr lang "Usage: /settings <key> <value>")
  | otherwise = runSettingsCommand lang (key <> " " <> raw)

executeCommand lang bridge sessionRef modelRef (RunCustom name args) = do
  cmds <- loadCustomCommands
  case [ cc | cc <- cmds, ccName cc == name ] of
    (cc : _) -> executeCommand lang bridge sessionRef modelRef
                  (SendMessage (renderCustomCommand cc args))
    [] -> return $ Just $ tr lang "Unknown command: /" <> name

executeCommand _ _ _ _ Sandbox = do
  enabled <- lookupEnv "TRHA_SANDBOX"
  let state = case fmap (T.toLower . T.strip . T.pack) enabled of
        Just v | v `elem` ["on", "1", "true", "enforce"] -> "on"
        _ -> "off"
  let label = if state == "on" then "enabled" else "disabled"
  return $ Just ("SandBox: " <> label
    <> " (TUI: /sandbox opens the panel; the scheduler reads TRHA_SANDBOX)")

executeCommand _ _ _ _ cmd =
  return $ Just ("Command not available in this front-end: " <> T.pack (show cmd))

-- | 快照文件名 @&lt;stamp&gt;-&lt;sha1前8位&gt;-&lt;basename&gt;@ 里取 basename。
-- stamp 自己也含 @-@，所以按「第一个 8 位十六进制段」定位分隔点。

-- | 在 root 下按文件名找文件（跳过 .git/依赖目录，深度上限 6）。

-- | 从 @~/.trha/provider-keys.json@ 读一个 provider 的 key（只在本机进程内用）。
readProviderKey :: Text -> IO (Maybe Text)
readProviderKey name = do
  home <- getHomeDirectory
  let path = home </> ".trha" </> "provider-keys.json"
  ok <- doesFileExist path
  if not ok
    then return Nothing
    else do
      raw <- BSL.readFile path
      return $ case decode raw of
        Just (Object o) -> case KeyMap.lookup "keys" o of
          Just (Object ks) -> case KeyMap.lookup (AesonKey.fromText name) ks of
            Just (String k) -> Just k
            _ -> Nothing
          _ -> Nothing
        _ -> Nothing

-- | @git rev-list --count@ 的输出。
gitCount :: (ExitCode, String, String) -> Text
gitCount (_, out, _) = T.strip (T.pack out)

-- | 可恢复会话 = 本地 transcript ∪ 调度层（stateDir 恢复的）会话。
--
-- 本地有的带标题与轮次；只在调度层存在的补一条最小摘要——它没有本地
-- transcript，历史由 'resumeMessages' 从调度层拉回来。
jsonStr :: Text -> Object -> Text
jsonStr k o = fromMaybe "" (jsonMaybeStr k o)

-- | 取 JSON 对象的可选字符串字段。
jsonMaybeStr :: Text -> Object -> Maybe Text
jsonMaybeStr k o = case KeyMap.lookup (AesonKey.fromText k) o of
  Just (String s) -> Just s
  _               -> Nothing
