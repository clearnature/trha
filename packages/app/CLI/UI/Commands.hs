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
  ) where

import Data.Aeson (object, (.=))
import Core.Types
import Bridge.Scheduler (SchedulerBridge, listPlugins, listSessions, createSession, deleteSession, sendMessage, sendMessageWithUsage, sendMessageWithEffort, listModels, listProviders, planStep, approvePlan, denyPlan, denyPlanWithReason, subscribeSessionEvents, submitPlan, decideStep, fetchPlan, fetchSessionInfo, fetchAgents, renameSession, tagSession, fetchSessionMode, applySessionMode, reportStep, fetchBalance, fetchUsageStats, UsageRow(..), compactSession, retrySession, btwAsk, recapSession, queueMessage, fetchQueue, steerSession, forkSession, branchSession, setInUseProvider, startLoop, fetchLoops, stopLoops, listWorkflows, runWorkflow, fetchServiceStatus)
import UI.ProviderPresets (presets, preBaseUrl, preKind, preName)
import Core.Currency (CurrencyTable(..), loadCurrency, saveCurrency)
import Core.Replay (ReplayBlock(..), renderReplay, renderReplayText)
import Core.Export (exportMarkdown, exportJson, defaultExportName)
import Core.TurnStats (Prices(..), pricesForModel, turnSummary)
import Core.SessionSummary (SessionSummary(..), pickLocalSession)
import Core.Memory (allMemories, rememberText)
import Core.ProjectStore (ProjectSession(..), projectSessions)
import Core.Transcript (listLocalSessions, loadTranscript, recordChunk, recordModelRequest, recordSession, recordToolEvent, recordUser)
import Control.Concurrent (threadDelay)
import Control.Exception (IOException, catch, try)
import qualified Data.Map as Map
import Data.IORef
import Data.List (partition)
import Data.Text (Text)
import qualified Data.Text as T
import System.IO (hClose, hFlush, hPutStr, openTempFile, stdout)
import System.Environment (lookupEnv)
import Data.Maybe (fromMaybe)
import Core.Clipboard (saveClipboardImage)
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist, getHomeDirectory, getTemporaryDirectory, listDirectory, removeFile)
import System.FilePath ((</>))
import System.Exit (ExitCode(..))
import System.Process (readProcessWithExitCode)
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
import UI.CustomCommands (CustomCommand(..), loadCustomCommands, renderCustomCommand)
import UI.Theme (Theme(..), themes, themeNames, resolveTheme)
import UI.Render.Sidebar (agentTreeLines)
import System.Directory (getCurrentDirectory)
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
executeCommand :: Lang -> SchedulerBridge -> IORef (Maybe SessionId) -> IORef Text -> Command -> IO (Maybe Text)
-- | Parse a loop interval: @30s@, @5m@, @1h@, or plain seconds.
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

executeCommand lang _ _ _ Help = return $ Just (registryHelp lang)

executeCommand _ _ _ _ Quit = return Nothing

-- | @/stop@ needs an explicit confirmation: stopping the backend leaves the
-- shell with nothing to talk to, so a single keystroke must not do it.
executeCommand lang _ _ _ StopRequest =
  return $ Just (tr lang "This stops the kernel and scheduler and exits. Type /stop confirm to proceed.")

executeCommand _ _ _ _ StopConfirmed = return Nothing

executeCommand lang bridge _ _ Sessions = do
  result <- listSessions bridge
  return $ Just $ case result of
    Right sessions -> if null sessions
      then tr lang "No active sessions"
      else (tr lang "Sessions:" <> "\n") <> T.unlines (map (\s -> "  - " <> T.pack s) sessions)
    Left err -> tr lang "Error: " <> T.pack (show err)

executeCommand lang bridge sessionRef modelRef CreateSession = do
  result <- createSession bridge
  case result of
    Right sid -> do
      writeIORef sessionRef (Just sid)
      model <- readIORef modelRef
      recordSession sid model
      return $ Just $ tr lang "Session created: " <> T.pack sid
    Left err -> return $ Just $ tr lang "Error: " <> T.pack (show err)

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

executeCommand lang _ _ _ Clear = do
  callCommand "clear"
  return Nothing

executeCommand lang _ sessionRef modelRef Status = do
  session <- readIORef sessionRef
  model <- readIORef modelRef
  return $ Just $ T.unlines
    [ tr lang "Status:"
    , tr lang "  Current session: " <> maybe (tr lang "none") T.pack session
    , tr lang "  Current model: " <> model
    ]

executeCommand lang _ sessionRef _ (Export args) = do
  cur <- readIORef sessionRef
  case cur of
    Nothing -> return $ Just (tr lang "No session to export")
    Just sid -> do
      evs <- loadTranscript sid
      nowT <- getCurrentTime
      tz <- getCurrentTimeZone
      home <- getHomeDirectory
      let stamp = T.pack (formatTime defaultTimeLocale "%Y%m%d-%H%M%S" (utcToZonedTime tz nowT))
          parts = T.words args
          asJson = case parts of
            (a : _) -> T.toLower a == "json"
            []      -> False
          explicit = case parts of
            (a : b : _) | T.toLower a `elem` ["json", "md", "markdown"] -> Just b
            (a : _) | T.toLower a `notElem` ["json", "md", "markdown"] -> Just a
            _ -> Nothing
          ext = if asJson then "json" else "md"
          dir = home </> ".trha" </> "exports"
          path = case explicit of
            Just p
              | "/" `T.isPrefixOf` p -> T.unpack p
              | otherwise            -> dir </> T.unpack p
            Nothing -> dir </> defaultExportName (T.pack sid) stamp ext
          body = if asJson then exportJson (T.pack sid) stamp evs
                           else exportMarkdown (T.pack sid) stamp evs
      written <- try (do
        createDirectoryIfMissing True (takeDirectory path)
        TIO.writeFile path body) :: IO (Either IOException ())
      return $ Just $ case written of
        Right () -> "exported → " <> T.pack path
        Left e   -> "export failed: " <> T.pack (show e)

executeCommand _ _ _ _ (StashDraft args) = do
  s <- loadStash
  let listing st = case stashEntries st of
        [] -> "stash is empty"
        es -> T.unlines
          [ T.pack (show i) <> ". " <> T.take 60 (T.replace "\n" " " e)
          | (i, e) <- zip [(1 :: Int) ..] es ]
  case T.words args of
    [] -> return $ Just (listing s)
    ("list" : _) -> return $ Just (listing s)
    ("pop" : _) -> case stashPop s of
      Nothing -> return $ Just "stash is empty"
      Just (draft, s') -> do
        saveStash s'
        return $ Just ("restored: " <> draft)
    _ -> do
      let s' = stashPush (T.strip args) s
      saveStash s'
      return $ Just "draft stashed"

executeCommand _ _ _ modelRef (Fav arg) = do
  m <- readIORef modelRef
  p <- loadModelPrefs
  let name = if T.null (T.strip arg) then m else T.strip arg
      p' = toggleFavorite name p
  saveModelPrefs p'
  return $ Just ("favourite: " <> name)

executeCommand _ _ _ _ Skills = do
  cwd <- getCurrentDirectory
  dirs <- skillDirs cwd
  skills <- scanSkills dirs
  return $ Just $ if null skills
    then "No skills found (put SKILL.md under .agents/skills or .trha/skills)."
    else T.unlines [ "  • " <> skName s <> " — " <> skDescription s | s <- skills ]

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

executeCommand _ _ _ _ Home =
  return $ Just "Home is the TUI launch screen (run: trha tui)"

executeCommand _ _ _ _ CopyLast =
  return $ Just "Copy is available in the TUI (run: trha tui, then /copy)"

executeCommand _ _ _ _ Verbose =
  return $ Just "Verbose is available in the TUI (/verbose)"

executeCommand lang bridge sessionRef _ Todo = do
  msid <- readIORef sessionRef
  case msid of
    Nothing -> return $ Just (tr lang "No active session.")
    Just sid -> do
      r <- fetchSessionInfo bridge sid
      return $ Just $ case r of
        Right info
          | null (siTodos info) -> tr lang "No tasks"
          | otherwise -> T.unlines
              [ "  " <> glyph (todoStatus i) <> " " <> todoSubject i | i <- siTodos info ]
        Left e -> T.pack (show e)
  where
    glyph TodoPending    = "○"
    glyph TodoInProgress = "◐"
    glyph TodoDone       = "●"

executeCommand _ bridge _ _ Tree = do
  r <- fetchAgents bridge
  return $ Just $ case r of
    Right [] -> "no agents"
    Right as -> T.unlines (agentTreeLines Nothing as)
    Left e   -> T.pack (show e)

executeCommand lang bridge sessionRef _ (Rename title) = do
  msid <- readIORef sessionRef
  case msid of
    Nothing -> return $ Just (tr lang "No active session.")
    Just sid -> do
      r <- renameSession bridge sid title
      return $ Just $ either (T.pack . show) (const ("renamed: " <> title)) r

executeCommand lang bridge sessionRef _ (Tag tags) = do
  msid <- readIORef sessionRef
  case msid of
    Nothing -> return $ Just (tr lang "No active session.")
    Just sid -> do
      r <- tagSession bridge sid (T.words tags)
      return $ Just $ either (T.pack . show) (const ("tags: " <> tags)) r

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

executeCommand lang _ _ _ ShowMemory = do
  entries <- allMemories
  if null entries
    then return $ Just $ tr lang "No memory notes yet (use /remember <text>)."
    else return $ Just $ T.intercalate "\n\n"
           [ "# " <> name <> "\n" <> body | (name, body) <- entries ]

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

executeCommand lang _ _ _ Cls = do
  -- The REPL clears the terminal; the TUI treats it as "clear the view".
  callCommand "clear" `catch` \(_ :: IOException) -> pure ()
  return $ Just (tr lang "Cleared (history is kept).")

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

executeCommand lang bridge sessionRef _ (Workflow arg) = do
  cur <- readIORef sessionRef
  case cur of
    Nothing -> return $ Just (tr lang "No active session.")
    Just sid -> case T.words (T.strip arg) of
      [] -> do
        r <- listWorkflows bridge
        return $ Just $ case r of
          Left e -> tr lang "Error: " <> T.pack (show e)
          Right [] -> tr lang "No workflows."
          Right ws -> T.unlines
            (tr lang "Workflows:" : [ "  " <> n <> "  " <> d | (n, d) <- ws ])
      (name : rest) -> do
        r <- runWorkflow bridge sid name (T.unwords rest)
        return $ Just $ case r of
          Left e -> tr lang "Error: " <> T.pack (show e)
          Right reply -> reply

executeCommand lang bridge sessionRef _ Graph = do
  agents <- fetchAgents bridge
  cur <- readIORef sessionRef
  rows <- maybe (pure []) loadTranscript cur
  let blocks = renderReplay rows
      tools = [ nm | ReplayBlock { rbTool = Just (nm, _) } <- blocks ]
      counts = Map.toList (Map.fromListWith (+) [ (nm, 1 :: Int) | nm <- tools ])
      tree = case agents of
        Left e -> [ "  ! " <> T.pack (show e) ]
        Right as -> [ "  - " <> aeId a | a <- as ]
  return $ Just $ T.unlines $
    [ tr lang "Graph:", tr lang "  session: " <> maybe "-" T.pack cur ]
    ++ [ "  - " <> T.pack nm <> " x" <> T.pack (show n) | (nm, n) <- counts ]
    ++ tree

executeCommand lang bridge sessionRef _ (Loop arg) = do
  cur <- readIORef sessionRef
  case cur of
    Nothing -> return $ Just (tr lang "No active session.")
    Just sid
      | T.toLower (T.strip arg) == "stop" -> do
          r <- stopLoops bridge sid
          return $ Just $ case r of
            Left e -> tr lang "Error: " <> T.pack (show e)
            Right n -> tr lang "Stopped " <> T.pack (show n) <> tr lang " loop(s)."
      | T.null (T.strip arg) -> do
          r <- fetchLoops bridge sid
          return $ Just $ case r of
            Left e -> tr lang "Error: " <> T.pack (show e)
            Right [] -> tr lang "No active loops."
            Right ls -> T.unlines (tr lang "Loops:" : map ("  - " <>) ls)
      | otherwise -> case T.words (T.strip arg) of
          (iv : rest) | Just ms <- parseInterval iv, not (null rest) -> do
            r <- startLoop bridge sid ms (T.unwords rest)
            return $ Just $ case r of
              Left e -> tr lang "Error: " <> T.pack (show e)
              Right lid -> tr lang "Loop started: " <> lid
          _ -> return $ Just (tr lang "Usage: /loop <30s|5m|1h> <prompt> | /loop stop")

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

executeCommand lang bridge sessionRef _ GoalView = do
  cur <- readIORef sessionRef
  case cur of
    Nothing -> return $ Just (tr lang "No active session.")
    Just sid -> do
      info <- fetchSessionInfo bridge sid
      return $ Just $ case info of
        Left e -> tr lang "Error: " <> T.pack (show e)
        Right si -> T.unlines
          [ tr lang "Goal: " <> fromMaybe (tr lang "none") (siGoal si)
          , tr lang "Todos: " <> T.pack (show (length (siTodos si)))
          ]

executeCommand lang bridge sessionRef _ (Fork _title) = do
  cur <- readIORef sessionRef
  case cur of
    Nothing -> return $ Just (tr lang "No active session.")
    Just sid -> do
      r <- forkSession bridge sid Nothing
      case r of
        Left e -> return $ Just (tr lang "Error: " <> T.pack (show e))
        Right newSid -> do
          writeIORef sessionRef (Just newSid)
          return $ Just (tr lang "Forked: " <> T.pack newSid)

executeCommand lang bridge sessionRef _ Branch = do
  cur <- readIORef sessionRef
  case cur of
    Nothing -> return $ Just (tr lang "No active session.")
    Just sid -> do
      r <- branchSession bridge sid
      case r of
        Left e -> return $ Just (tr lang "Error: " <> T.pack (show e))
        Right newSid -> do
          writeIORef sessionRef (Just newSid)
          return $ Just (tr lang "Branched: " <> T.pack newSid)

executeCommand lang bridge sessionRef _ (Steer prompt)
  | T.null (T.strip prompt) = return $ Just (tr lang "Usage: /steer <prompt>")
  | otherwise = do
      cur <- readIORef sessionRef
      case cur of
        Nothing -> return $ Just (tr lang "No active session.")
        Just sid -> do
          r <- steerSession bridge sid (T.strip prompt)
          return $ Just $ case r of
            Left e -> tr lang "Error: " <> T.pack (show e)
            Right n -> tr lang "Steered (" <> T.pack (show n) <> tr lang " pending)"

executeCommand lang bridge sessionRef _ (Queue Nothing) = do
  cur <- readIORef sessionRef
  case cur of
    Nothing -> return $ Just (tr lang "No active session.")
    Just sid -> do
      r <- fetchQueue bridge sid
      return $ Just $ case r of
        Left e -> tr lang "Error: " <> T.pack (show e)
        Right [] -> tr lang "Queue is empty."
        Right ms -> T.unlines (tr lang "Queued:" : map ("  - " <>) ms)

executeCommand lang bridge sessionRef _ (Queue (Just text))
  | T.null (T.strip text) = return $ Just (tr lang "Usage: /queue <message>")
  | otherwise = do
      cur <- readIORef sessionRef
      case cur of
        Nothing -> return $ Just (tr lang "No active session.")
        Just sid -> do
          r <- queueMessage bridge sid (T.strip text)
          return $ Just $ case r of
            Left e -> tr lang "Error: " <> T.pack (show e)
            Right n -> tr lang "Queued (" <> T.pack (show n) <> tr lang " pending)"

executeCommand lang bridge sessionRef _ Recap = do
  cur <- readIORef sessionRef
  case cur of
    Nothing -> return $ Just (tr lang "No active session.")
    Just sid -> do
      r <- recapSession bridge sid
      return $ Just $ case r of
        Left e -> tr lang "Error: " <> T.pack (show e)
        Right summary
          | T.null (T.strip summary) -> tr lang "Nothing to recap yet."
          | otherwise -> summary

executeCommand lang bridge sessionRef _ (Btw question) = do
  cur <- readIORef sessionRef
  case cur of
    Nothing -> return $ Just (tr lang "No active session.")
    Just sid
      | T.null (T.strip question) -> return $ Just (tr lang "Usage: /btw <question>")
      | otherwise -> do
          r <- btwAsk bridge sid (T.strip question)
          return $ Just $ case r of
            Left e -> tr lang "Error: " <> T.pack (show e)
            Right answer -> answer

executeCommand lang bridge sessionRef _ Retry = do
  cur <- readIORef sessionRef
  case cur of
    Nothing -> return $ Just (tr lang "No active session.")
    Just sid -> do
      r <- retrySession bridge sid
      return $ Just $ case r of
        Left e -> tr lang "Error: " <> T.pack (show e)
        Right reply -> reply

executeCommand lang bridge sessionRef _ SessionInfoView = do
  cur <- readIORef sessionRef
  case cur of
    Nothing -> return $ Just (tr lang "No active session.")
    Just sid -> do
      info <- fetchSessionInfo bridge sid
      mode <- fetchSessionMode bridge sid
      return $ Just $ case info of
        Left e -> tr lang "Error: " <> T.pack (show e)
        Right si -> T.unlines $
          [ tr lang "Session: " <> T.pack sid
          , tr lang "  mode: " <> either (const (tr lang "unknown")) smLabel mode
          , tr lang "  goal: " <> fromMaybe (tr lang "none") (siGoal si)
          , tr lang "  todos: " <> T.pack (show (length (siTodos si)))
          ] ++ [ "  - " <> todoSubject t <> " [" <> T.pack (show (todoStatus t)) <> "]"
               | t <- siTodos si ]

executeCommand lang _ sessionRef _ TranscriptView = do
  cur <- readIORef sessionRef
  case cur of
    Nothing -> return $ Just (tr lang "No active session.")
    Just sid -> do
      rows <- loadTranscript sid
      if null rows
        then return $ Just (tr lang "No transcript for this session yet.")
        else return $ Just (renderReplayText (renderReplay rows))

executeCommand lang _ _ _ (Paste text) = do
  r <- saveClipboardImage
  return $ Just $ case r of
    Nothing -> tr lang "No image in clipboard"
    Just path -> tr lang "Image saved: " <> T.pack path
      <> (if T.null (T.strip text) then "" else " (" <> T.strip text <> ")")

executeCommand lang _ _ _ EditPrompt = do
  tmp <- getTemporaryDirectory
  (path, h) <- openTempFile tmp "trha-edit.txt"
  hClose h
  ed <- do
    v <- lookupEnv "EDITOR"
    case v of
      Just e | not (null e) -> pure e
      _ -> fromMaybe "vi" <$> lookupEnv "VISUAL"
  (code, _, err) <- readProcessWithExitCode ed [path] ""
  body <- TIO.readFile path `catch` \(_ :: IOException) -> pure ""
  removeFile path `catch` \(_ :: IOException) -> pure ()
  return $ Just $ if code /= ExitSuccess
    then tr lang "Editor failed: " <> T.pack err
    else body

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

executeCommand lang _ _ _ ShowAttachments = do
  home <- getHomeDirectory
  let dir = home </> ".trha" </> "paste"
  ok <- doesDirectoryExist dir
  if not ok
    then return $ Just (tr lang "No attachments.")
    else do
      fs <- listDirectory dir
      return $ Just $ if null fs
        then tr lang "No attachments."
        else T.unlines (tr lang "Attachments:" : map T.pack fs)

executeCommand lang _ _ _ ClearAttachments = do
  home <- getHomeDirectory
  let dir = home </> ".trha" </> "paste"
  ok <- doesDirectoryExist dir
  if not ok
    then return $ Just (tr lang "No attachments.")
    else do
      fs <- listDirectory dir
      mapM_ (removeFile . (dir </>)) fs
      return $ Just $ tr lang "Cleared " <> T.pack (show (length fs)) <> tr lang " attachments."

executeCommand lang bridge _ _ ShowMcp = do
  (_, mcp) <- fetchServiceStatus bridge
  return $ Just $ T.unlines (tr lang "MCP:" : map ("  " <>) mcp)

executeCommand lang bridge _ _ ShowLsp = do
  (lsp, _) <- fetchServiceStatus bridge
  return $ Just $ T.unlines (tr lang "LSP:" : map ("  " <>) lsp)

executeCommand lang _ _ _ ShowPresets =
  return $ Just $ T.unlines
    ( tr lang "Provider presets:" :
      [ "  " <> preName p <> " (" <> preKind p <> ") " <> preBaseUrl p | p <- presets ] )

executeCommand lang _ _ _ ShowHooks = do
  home <- getHomeDirectory
  let dir = home </> ".trha" </> "hooks"
  ok <- doesDirectoryExist dir
  if not ok
    then return $ Just (tr lang "No hooks.")
    else do
      fs <- listDirectory dir
      return $ Just $ if null fs
        then tr lang "No hooks."
        else T.unlines (tr lang "Hooks:" : map T.pack fs)

executeCommand lang bridge sessionRef _ (Compact _focus) = do
  cur <- readIORef sessionRef
  case cur of
    Nothing -> return $ Just (tr lang "No active session.")
    Just sid -> do
      r <- compactSession bridge sid
      return $ Just $ case r of
        Left e -> tr lang "Error: " <> T.pack (show e)
        Right (trigger, saved) ->
          tr lang "Compacted (" <> trigger <> tr lang "): saved "
            <> T.pack (show saved) <> tr lang " tokens"

executeCommand lang bridge _ _ ShowUsage = do
  bal <- fetchBalance bridge
  cfg <- resolveConfig defaultCLIConfig
  return $ Just $ T.unlines
    [ tr lang "Usage:"
    , tr lang "  model: " <> configModel cfg
    , tr lang "  balance: " <> either (const (tr lang "unavailable"))
        (\b -> balanceCurrency b <> " " <> T.pack (show (balanceTotal b))) bal
    ]

executeCommand lang _ _ _ (Remember text) =
  if T.null (T.strip text)
    then return $ Just $ tr lang "Usage: /remember <text>"
    else do
      rememberText text
      return $ Just $ tr lang "Remembered: " <> T.strip text

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

executeCommand lang bridge _ _ Plugins = do
  result <- listPlugins bridge
  return $ Just $ case result of
    Right [] -> tr lang "No plugins registered."
    Right ps -> (tr lang "Plugins:" <> "\n") <> T.unlines
      [ "  - " <> pluginName p <> " " <> pluginVersion p
          <> maybe "" (\d -> "  —  " <> d) (Just (pluginDescription p))
      | p <- ps ]
    Left err -> tr lang "Error: " <> T.pack (show err)

executeCommand lang _ _ _ (Unknown cmd) =
  return $ Just $ tr lang "Unknown command: " <> cmd <> tr lang " — try /help"

-- | Submit a plan. One line goes through the single-command gate; two or more
-- (separated by @;@ or newlines) become a stepwise plan in the kernel, decided
-- one step at a time.
executeCommand lang bridge sessionRef _ (Plan planText) = do
  if T.null (T.strip planText)
    then return $ Just (tr lang "Usage: /plan <what to do>")
    else do
      session <- readIORef sessionRef
      case session of
        Nothing -> return $ Just (tr lang "No active session. Use /new to create one.")
        Just sid -> do
          recordUser sid planText
          let steps = splitPlanSteps planText
          if length steps >= 2
            then do
              result <- submitPlan bridge sid steps
              return $ Just $ case result of
                Right pv -> T.unlines
                  [ tr lang "Plan submitted — decide each step with /approve, /skip, /reject or /abandon."
                  , renderPlanBrief pv ]
                Left err -> tr lang "Error: " <> T.pack (show err)
            else do
              result <- planStep bridge sid planText
              return $ Just $ case result of
                Right (PlanAwaiting preview) ->
                  T.unlines [ tr lang "⏸ Plan submitted — awaiting your decision (/approve or /deny)."
                            , tr lang "Plan: " <> preview ]
                Left err -> tr lang "Error: " <> T.pack (show err)

-- | Skip / reject the pending step, or drop the whole plan.
executeCommand lang bridge sessionRef _ SkipStep = decidePlanStep lang bridge sessionRef "skip"
executeCommand lang bridge sessionRef _ RejectStep = decidePlanStep lang bridge sessionRef "reject"
executeCommand lang bridge sessionRef _ AbandonPlan = decidePlanStep lang bridge sessionRef "abandon"

-- | Approve. If a multi-step plan is active in the kernel, approve its pending
-- step, run it as a normal agent turn, then report the result; otherwise the
-- single-command gate answers.
executeCommand lang bridge sessionRef _ Approve = do
  session <- readIORef sessionRef
  case session of
    Nothing -> return $ Just (tr lang "No active session. Use /new to create one.")
    Just sid -> do
      mplan <- fetchPlan bridge sid
      case mplan of
        Right pv | pvPhase pv == "planning" -> approvePlanStep lang bridge sid
        _ -> do
          result <- approvePlan bridge sid
          case result of
            Right (PlanApproved reply) -> do
              recordChunk sid (Right (ChunkDelta reply))
              return $ Just reply
            Right PlanDenied -> return $ Just (tr lang "Plan was not approved.")
            Left err -> return $ Just $ tr lang "Error: " <> T.pack (show err)

executeCommand lang bridge sessionRef _ (DenyWith reason) = do
  session <- readIORef sessionRef
  case session of
    Nothing -> return $ Just (tr lang "No active session. Use /new to create one.")
    Just sid -> do
      result <- denyPlanWithReason bridge sid reason
      return $ Just $ case result of
        Right PlanDenied -> tr lang "Plan denied."
        Right (PlanApproved _) -> tr lang "Plan was approved (unexpected)."
        Left err -> T.pack (show err)

-- | Deny: on a plan that means rejecting the pending step.
executeCommand lang bridge sessionRef _ Deny = do
  session <- readIORef sessionRef
  case session of
    Nothing -> return $ Just (tr lang "No active session. Use /new to create one.")
    Just sid -> do
      mplan <- fetchPlan bridge sid
      case mplan of
        Right pv | pvPhase pv == "planning" -> decidePlanStep lang bridge sessionRef "reject"
        _ -> do
          result <- denyPlan bridge sid
          return $ Just $ case result of
            Right PlanDenied -> tr lang "Plan denied."
            Right (PlanApproved _) -> tr lang "Plan was approved (unexpected)."
            Left err -> tr lang "Error: " <> T.pack (show err)

-- | List local sessions (from ~/.trha transcript index).  Sessions of the
-- current project come first, using the @~/.trha/projects/<slug>@ index.
executeCommand lang _ _ _ ResumeList = do
  sessions <- listLocalSessions
  cwd <- getCurrentDirectory
  mine <- projectSessions cwd
  let mineIds = map psId mine
      (local, others) = partition (\s -> T.pack (ssId s) `elem` mineIds) sessions
      ordered = local ++ others
  return $ Just $ if null sessions
    then tr lang "No local sessions found. Run a conversation first (transcripts are stored under ~/.trha/sessions)."
    else (tr lang "Local sessions:" <> "\n") <> T.unlines
      [ "  [" <> T.pack (show (i :: Int)) <> "] " <> ssTitle s
          <> "  (" <> T.pack (ssId s)
          <> maybe "" (\m -> " · " <> m) (ssModel s)
          <> " · " <> T.pack (show (ssTurns s)) <> tr lang " turn(s)"
          <> maybe "" (\ts -> " · " <> ts) (ssLastTs s)
          <> ")"
      | (i, s) <- zip [1 :: Int ..] ordered ]

-- | Resume a local session by list number or id: replay its transcript
-- and set it as the active session (continuing works while the
-- orchestration layer still holds it).
executeCommand lang _ sessionRef _ (ResumeSelect sel) = do
  sessions <- listLocalSessions
  case pickLocalSession sel sessions of
    Nothing -> return $ Just $ tr lang "No local session matches: " <> T.pack sel
    Just s -> do
      events <- loadTranscript (ssId s)
      let replay = renderReplayText (renderReplay events)
      writeIORef sessionRef (Just (ssId s))
      return $ Just $
        (if T.null replay
           then tr lang "Resumed " <> T.pack (ssId s) <> tr lang " (empty transcript)"
           else tr lang "Resumed " <> T.pack (ssId s) <> ":\n" <> replay)
        <> "\n" <> tr lang "Note: continuing needs the session on the orchestration side."

executeCommand lang bridge sessionRef modelRef (RunCustom name args) = do
  cmds <- loadCustomCommands
  case [ cc | cc <- cmds, ccName cc == name ] of
    (cc : _) -> executeCommand lang bridge sessionRef modelRef
                  (SendMessage (renderCustomCommand cc args))
    [] -> return $ Just $ tr lang "Unknown command: /" <> name

executeCommand lang bridge sessionRef modelRef (SendMessage msg) = do
  session <- readIORef sessionRef
  case session of
    Nothing -> return $ Just (tr lang "No active session. Use /new to create one.")
    Just sid -> do
      recordUser sid msg
      model <- readIORef modelRef
      recordModelRequest sid model
      toolRef <- newIORef ([] :: [ToolEvent])
      cancel <- subscribeSessionEvents bridge sid $ \ev -> case ev of
        Right tev -> do
          recordToolEvent sid tev
          modifyIORef' toolRef (tev :)
        Left _ -> return ()
      cfg <- resolveConfig defaultCLIConfig
      let eff = if T.toLower (configEffort cfg) == "auto"
                  then Nothing else Just (configEffort cfg)
      cfg <- resolveConfig defaultCLIConfig
      let mlang = effectiveReasoningLanguage cfg
      result <- sendMessageWithEffort bridge sid eff mlang msg
      threadDelay 100000 -- drain trailing tool events before tearing down
      cancel
      recordChunk sid (fst <$> result)
      tools <- readIORef toolRef
      let toolLines = T.unlines
            [ T.unlines (toolCardWithStatus (T.pack (teName ev)) (teArgs ev)
                           (toCardStatus (teStatus ev)) (teDurationMs ev))
            | ev <- reverse tools
            , teStatus ev /= ToolRunRunning
            ]
      prices <- pricesFromEnv
      nowT <- getCurrentTime
      return $ Just $ case result of
        Right (chunk, _) -> toolLines <> case chunk of
          ChunkDelta text -> text
          ChunkToolCall name args -> "[Tool call: " <> T.pack name <> " " <> T.unwords args <> "]"
          ChunkDone usage -> turnSummary prices usage (usageReasoningTokens usage) nowT
        Left err -> toolLines <> tr lang "Error: " <> T.pack (show err)

executeCommand _ _ _ _ Sandbox = do
  enabled <- lookupEnv "TRHA_SANDBOX"
  let state = case fmap (T.toLower . T.strip . T.pack) enabled of
        Just v | v `elem` ["on", "1", "true", "enforce"] -> "on"
        _ -> "off"
  let label = if state == "on" then "enabled" else "disabled"
  return $ Just ("SandBox: " <> label
    <> " (TUI: /sandbox opens the panel; the scheduler reads TRHA_SANDBOX)")

executeCommand lang bridge _ _ Agents = do
  r <- fetchAgents bridge
  return $ Just $ case r of
    Left err -> tr lang "Error: " <> T.pack (show err)
    Right as -> T.unlines (tr lang "Agents:" : [ "  - " <> aeId a | a <- as ])

executeCommand lang bridge sessionRef _ SkipStep = decidePlanStep lang bridge sessionRef "skip"
executeCommand lang bridge sessionRef _ RejectStep = decidePlanStep lang bridge sessionRef "reject"
executeCommand lang bridge sessionRef _ AbandonPlan = decidePlanStep lang bridge sessionRef "reject"

-- Catch-all: a command registered only for the TUI must not crash the REPL with
-- a non-exhaustive pattern match.
executeCommand _ _ _ _ cmd =
  return $ Just ("Command not available in this front-end: " <> T.pack (show cmd))

-- | Map the wire tool status to the card status type.
toCardStatus :: ToolRunStatus -> ToolStatus
toCardStatus s = case s of
  ToolRunRunning   -> ToolRunning
  ToolRunSucceeded -> ToolSucceeded
  ToolRunFailed e  -> ToolFailed e

-- | One plan decision, rendered as a compact list.
decidePlanStep :: Lang -> SchedulerBridge -> IORef (Maybe SessionId) -> Text -> IO (Maybe Text)
decidePlanStep lang bridge sessionRef action = do
  session <- readIORef sessionRef
  case session of
    Nothing -> return $ Just (tr lang "No active session. Use /new to create one.")
    Just sid -> do
      result <- decideStep bridge sid action
      return $ Just $ case result of
        Right pv -> renderPlanBrief pv
        Left err -> tr lang "Error: " <> T.pack (show err)

-- | Release the pending plan step, run it, and report back — the same shape the
-- TUI and Desktop use, so all three shells tell the kernel the truth.
approvePlanStep :: Lang -> SchedulerBridge -> SessionId -> IO (Maybe Text)
approvePlanStep lang bridge sid = do
  approved <- decideStep bridge sid "approve"
  case approved of
    Left err -> return $ Just $ tr lang "Error: " <> T.pack (show err)
    Right pv -> case planStepOut pv of
      Nothing -> return $ Just (renderPlanBrief pv)
      Just step -> do
        ran <- sendMessage bridge sid (psvTitle step)
        let ok = either (const False) (const True) ran
            reply = either (const "") chunkText ran
        recorded <- reportStep bridge sid (psvId step) ok
        case recorded of
          Left err -> return $ Just $ tr lang "Error: " <> T.pack (show err)
          Right pv' -> do
            recordChunk sid (Right (ChunkDelta reply))
            return $ Just (reply <> "\n" <> renderPlanBrief pv')
  where
    chunkText (ChunkDelta t) = t
    chunkText _              = ""

-- | Prices from @TRHA_PRICE_INPUT@ / @TRHA_PRICE_CACHED@ / @TRHA_PRICE_OUTPUT@
-- (CNY per 1M tokens).  Zero when unset, which renders as @≈¥—@.
pricesFromEnv :: IO Prices
pricesFromEnv = do
  i <- lookupEnv "TRHA_PRICE_INPUT"
  c <- lookupEnv "TRHA_PRICE_CACHED"
  o <- lookupEnv "TRHA_PRICE_OUTPUT"
  pure (Prices (readD i) (readD c) (readD o))
  where
    readD = maybe 0 (\s -> maybe 0 id (readMaybe s))
