{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | 计划与审批、对话流控制命令：
-- @/plan /approve /deny /skip /reject /abandon /recap /retry /rewind /restore
-- /loop /queue /steer /btw@，外加消息文本与未知命令的兜底。
--
-- 领域模块之一（约定见 "UI.Commands.Env"）。
module UI.Commands.Plan
  ( runPlan
  , decidePlanStep
  , approvePlanStep
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
import UI.Commands.Session (friendlyDenyError)
import UI.Commands.Helpers (findFilesNamed, parseInterval, pricesFromEnv, snapshotBase, toCardStatus)
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

runPlan :: CmdEnv -> Command -> Maybe (IO (Maybe Text))
runPlan env = go
  where
    lang       = ceLang env
    bridge     = ceBridge env
    sessionRef = ceSession env
    modelRef   = ceModel env

    go (Loop arg) = Just $ do
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

    go (Rewind arg) = Just $ do
      cur <- readIORef sessionRef
      case cur of
        Nothing -> return $ Just (tr lang "No active session.")
        Just sid -> case readMaybe (T.unpack (T.strip arg)) :: Maybe Int of
          Just n | n > 0 -> do
            r <- forkSession bridge sid (Just n)
            case r of
              Left e -> return $ Just (tr lang "Error: " <> T.pack (show e))
              Right newSid -> do
                writeIORef sessionRef (Just newSid)
                return $ Just $ tr lang "Rewound to turn " <> T.pack (show n)
                                 <> tr lang ": " <> T.pack newSid
          _ -> return $ Just (tr lang "Usage: /rewind <n> (turn number, 1 = first)")

    -- | @/restore [n]@：从 @~/.trha/file-history@ 还原一次写前快照。
    --
    -- 快照文件名是 @&lt;stamp&gt;-&lt;sha1(路径)前8位&gt;-&lt;basename&gt;@，没有完整路径，
    -- 所以在当前目录树里按 basename 回找，唯一命中才写回（多个命中就列出来让人选）。

    go (Restore arg) = Just $ do
      home <- getHomeDirectory
      let dir = home </> ".trha" </> "file-history"
      present <- doesDirectoryExist dir
      if not present
        then return $ Just (tr lang "No file history yet (~/.trha/file-history).")
        else do
          names <- reverse . sort <$> listDirectory dir
          case readMaybe (T.unpack (T.strip arg)) :: Maybe Int of
            Just n | n >= 1 && n <= length names -> do
              let snap = names !! (n - 1)
              case snapshotBase snap of
                Nothing -> return $ Just (tr lang "Unrecognised snapshot: " <> T.pack snap)
                Just base -> do
                  cwd <- getCurrentDirectory
                  hits <- findFilesNamed cwd base
                  case hits of
                    [target] -> do
                      body <- TIO.readFile (dir </> snap)
                      TIO.writeFile target body
                      return $ Just $ tr lang "Restored " <> T.pack snap
                                       <> tr lang " -> " <> T.pack target
                    [] -> return $ Just $ tr lang "No file named " <> T.pack base
                                       <> tr lang " under " <> T.pack cwd
                    many -> return $ Just $ T.unlines
                      (tr lang "Several candidates — cd into the right tree and retry:"
                       : map (T.pack . ("  - " <>)) many)
            _ -> return $ Just $ T.unlines
              (tr lang "Recent snapshots (newest first):"
               : [ "  " <> T.pack (show i) <> ". " <> T.pack name
                 | (i, name) <- zip [1 :: Int ..] (take 20 names) ])
              <> tr lang "Use /restore <n>."

    -- | @/auth@：provider 的 key 状态；@/auth check <name>@ 让内核探测一次端点。

    go (Queue Nothing) = Just $ do
      cur <- readIORef sessionRef
      case cur of
        Nothing -> return $ Just (tr lang "No active session.")
        Just sid -> do
          r <- fetchQueue bridge sid
          return $ Just $ case r of
            Left e -> tr lang "Error: " <> T.pack (show e)
            Right [] -> tr lang "Queue is empty."
            Right ms -> T.unlines (tr lang "Queued:" : map ("  - " <>) ms)

    go Recap = Just $ do
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

    go (Btw question) = Just $ do
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

    -- | Change the session's workspace.
    --
    -- The *human* channel: the model has no tool that reaches this endpoint — its
    -- `cd` is clamped to the current workspace — so only a person typing this can
    -- move the sandbox root.

    go Retry = Just $ do
      cur <- readIORef sessionRef
      case cur of
        Nothing -> return $ Just (tr lang "No active session.")
        Just sid -> do
          r <- retrySession bridge sid
          return $ Just $ case r of
            Left e -> tr lang "Error: " <> T.pack (show e)
            Right reply -> reply

    go EditPrompt = Just $ do
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

    go (Unknown cmd) = Just $
      return $ Just $ tr lang "Unknown command: " <> cmd <> tr lang " — try /help"

    -- | Submit a plan. One line goes through the single-command gate; two or more
    -- (separated by @;@ or newlines) become a stepwise plan in the kernel, decided
    -- one step at a time.

    go (Plan planText) = Just $ do
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

    go SkipStep = Just $ decidePlanStep lang bridge sessionRef "skip"

    go RejectStep = Just $ decidePlanStep lang bridge sessionRef "reject"

    go AbandonPlan = Just $ decidePlanStep lang bridge sessionRef "abandon"

    -- | Approve. If a multi-step plan is active in the kernel, approve its pending
    -- step, run it as a normal agent turn, then report the result; otherwise the
    -- single-command gate answers.

    go Approve = Just $ do
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

    go (DenyWith reason) = Just $ do
      session <- readIORef sessionRef
      case session of
        Nothing -> return $ Just (tr lang "No active session. Use /new to create one.")
        Just sid -> do
          result <- denyPlanWithReason bridge sid reason
          return $ Just $ case result of
            Right PlanDenied -> tr lang "Plan denied."
            Right (PlanApproved _) -> tr lang "Plan was approved (unexpected)."
            Left err -> friendlyDenyError lang err

    -- | Deny: on a plan that means rejecting the pending step.

    go Deny = Just $ do
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
                Left err -> friendlyDenyError lang err

    -- | List local sessions (from ~/.trha transcript index).

    go (SendMessage msg) = Just $ do
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

    go SkipStep = Just $ decidePlanStep lang bridge sessionRef "skip"

    go RejectStep = Just $ decidePlanStep lang bridge sessionRef "reject"

    go AbandonPlan = Just $ decidePlanStep lang bridge sessionRef "reject"

    -- Catch-all: a command registered only for the TUI must not crash the REPL with
    -- a non-exhaustive pattern match.

    go (Steer prompt)
      | T.null (T.strip prompt) = Just $ return $ Just (tr lang "Usage: /steer <prompt>")
      | otherwise = Just $ do
          cur <- readIORef sessionRef
          case cur of
            Nothing -> return $ Just (tr lang "No active session.")
            Just sid -> do
              r <- steerSession bridge sid (T.strip prompt)
              return $ Just $ case r of
                Left e -> tr lang "Error: " <> T.pack (show e)
                Right n -> tr lang "Steered (" <> T.pack (show n) <> tr lang " pending)"


    go (Queue (Just text))
      | T.null (T.strip text) = Just $ return $ Just (tr lang "Usage: /queue <message>")
      | otherwise = Just $ do
          cur <- readIORef sessionRef
          case cur of
            Nothing -> return $ Just (tr lang "No active session.")
            Just sid -> do
              r <- queueMessage bridge sid (T.strip text)
              return $ Just $ case r of
                Left e -> tr lang "Error: " <> T.pack (show e)
                Right n -> tr lang "Queued (" <> T.pack (show n) <> tr lang " pending)"


    go _ = Nothing

decidePlanStep :: Lang -> SchedulerBridge -> IORef (Maybe SessionId) -> Text -> IO (Maybe Text)
decidePlanStep lang bridge sessionRef action = do
  session <- readIORef sessionRef
  case session of
    Nothing -> return $ Just (tr lang "No active session. Use /new to create one.")
    Just sid -> do
      -- /skip /reject /abandon 在没有待审批计划时应当直接说清楚，而不是把
      -- 请求打到内核换回一条 502。
      plan <- fetchPlan bridge sid
      case plan of
        Right pv | pvPhase pv /= "planning" ->
          return $ Just (tr lang "No pending plan — submit one with /plan first.")
        Left _ ->
          return $ Just (tr lang "No pending plan — submit one with /plan first.")
        _ -> do
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
