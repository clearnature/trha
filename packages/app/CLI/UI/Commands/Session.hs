{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | 会话生命周期命令：新建、删除、恢复、重命名、分支、导出、压缩、附件等。
--
-- 领域模块之一（约定见 "UI.Commands.Env"）。分支体从 UI.Commands 原样搬来，
-- 只把首行签名从 @executeCommand lang bridge sessionRef modelRef PAT@ 改成
-- @go PAT@，四个参数改为 where 绑定；分支体整体缩进 +4 进 where 块。
module UI.Commands.Session
  ( runSession
  , resumeSessions
  , resumeMessages
  , friendlyDenyError
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

runSession :: CmdEnv -> Command -> Maybe (IO (Maybe Text))
runSession env = go
  where
    lang       = ceLang env
    bridge     = ceBridge env
    sessionRef = ceSession env
    modelRef   = ceModel env

    go Sessions = Just $ do
      result <- listSessions bridge
      return $ Just $ case result of
        Right sessions -> if null sessions
          then tr lang "No active sessions"
          else (tr lang "Sessions:" <> "\n") <> T.unlines (map (\s -> "  - " <> T.pack s) sessions)
        Left err -> tr lang "Error: " <> T.pack (show err)

    go CreateSession = Just $ do
      result <- createSession bridge Nothing
      case result of
        Right sid -> do
          writeIORef sessionRef (Just sid)
          model <- readIORef modelRef
          recordSession sid model
          return $ Just $ tr lang "Session created: " <> T.pack sid
        Left err -> return $ Just $ tr lang "Error: " <> T.pack (show err)

    go Clear = Just $ do
      callCommand "clear"
      return Nothing

    go (Export args) = Just $ do
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

    go (StashDraft args) = Just $ do
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

    go Home = Just $
      return $ Just "Home is the TUI launch screen (run: trha tui)"

    go (Rename title) = Just $ do
      msid <- readIORef sessionRef
      case msid of
        Nothing -> return $ Just (tr lang "No active session.")
        Just sid -> do
          r <- renameSession bridge sid title
          return $ Just $ either (T.pack . show) (const ("renamed: " <> title)) r

    go (Tag tags) = Just $ do
      msid <- readIORef sessionRef
      case msid of
        Nothing -> return $ Just (tr lang "No active session.")
        Just sid -> do
          r <- tagSession bridge sid (T.words tags)
          return $ Just $ either (T.pack . show) (const ("tags: " <> tags)) r

    go Cls = Just $ do
      -- The REPL clears the terminal; the TUI treats it as "clear the view".
      callCommand "clear" `catch` \(_ :: IOException) -> pure ()
      return $ Just (tr lang "Cleared (history is kept).")

    go (Fork _title) = Just $ do
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

    go Branch = Just $ do
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

    -- | @/rewind <n>@：把会话回退到第 n 轮。fork 是无损的——新会话只带前 n 轮，
    -- 原会话原样留着，随时可以 @/resume@ 回去。

    go SessionInfoView = Just $ do
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

    go TranscriptView = Just $ do
      cur <- readIORef sessionRef
      case cur of
        Nothing -> return $ Just (tr lang "No active session.")
        Just sid -> do
          rows <- loadTranscript sid
          if null rows
            then return $ Just (tr lang "No transcript for this session yet.")
            else return $ Just (renderReplayText (renderReplay rows))

    go ShowAttachments = Just $ do
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

    go ClearAttachments = Just $ do
      home <- getHomeDirectory
      let dir = home </> ".trha" </> "paste"
      ok <- doesDirectoryExist dir
      if not ok
        then return $ Just (tr lang "No attachments.")
        else do
          fs <- listDirectory dir
          mapM_ (removeFile . (dir </>)) fs
          return $ Just $ tr lang "Cleared " <> T.pack (show (length fs)) <> tr lang " attachments."

    go (Compact _focus) = Just $ do
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

    go ResumeList = Just $ do
      cwd <- getCurrentDirectory
      -- Only this project's transcripts: another project's conversation resumed
      -- here would pull in its workspace and its files.
      sessions <- listLocalSessionsIn cwd
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

    go (ResumeSelect sel) = Just $ do
      sessions <- resumeSessions bridge
      case pickLocalSession sel sessions of
        Nothing -> return $ Just $ tr lang "No local session matches: " <> T.pack sel
        Just s -> do
          events <- loadTranscript (ssId s)
          let replay = renderReplayText (renderReplay events)
          -- 本地没有 transcript 时从调度层拉历史。
          remote <- if T.null (T.strip replay)
            then resumeMessages bridge (ssId s)
            else pure []
          let body = if T.null (T.strip replay)
                       then T.unlines [ role <> ": " <> content | (role, content) <- remote ]
                       else replay
          writeIORef sessionRef (Just (ssId s))
          -- 调度层会从 stateDir 恢复会话，所以先问一句它是否真的在：在就能
          -- 直接接着聊；不在的话本地回放仍可看，但新消息会 404。
          live <- fetchSessionInfo bridge (ssId s)
          let note = case live of
                Right _ -> tr lang "This session is live on the scheduler — keep going."
                Left _  -> tr lang "This session is not live on the scheduler; /new starts a fresh one."
          return $ Just $
            (if T.null (T.strip body)
               then tr lang "Resumed " <> T.pack (ssId s) <> tr lang " (empty transcript)"
               else tr lang "Resumed " <> T.pack (ssId s) <> ":\n" <> body)
            <> "\n" <> note

    go _ = Nothing

resumeSessions :: SchedulerBridge -> IO [SessionSummary]
resumeSessions bridge = do
  cwd <- getCurrentDirectory
  local <- listLocalSessionsIn cwd
  remote <- listSessions bridge
  let seen = map ssId local
      extra = case remote of
        Right ids -> [ SessionSummary sid (T.pack sid) 0 Nothing Nothing Nothing Nothing
                     | sid <- ids, sid `notElem` seen ]
        Left _ -> []
  pure (local ++ extra)

-- | 一条会话的 (role, content)：从调度层拉取（本地没有 transcript 时用）。
resumeMessages :: SchedulerBridge -> SessionId -> IO [(Text, Text)]
resumeMessages bridge sid = do
  r <- getMessages bridge sid
  pure $ case r of
    Right ms -> [ (messageRole m, messageContent m)
                | m <- ms, not (T.null (T.strip (messageContent m))) ]
    Left _   -> []

-- | @/deny@ 在没有待审批计划/审批时不该抛一段 JSON，直接说清楚。
friendlyDenyError :: Lang -> CLIError -> Text
friendlyDenyError lang (ServerError msg)
  | "No pending approval" `T.isInfixOf` msg
  = tr lang "Nothing to deny — no pending plan or approval."
friendlyDenyError lang err = tr lang "Error: " <> T.pack (show err)

-- | 取 JSON 对象的字符串字段（缺失时为空串）。
