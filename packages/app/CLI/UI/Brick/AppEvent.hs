{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | 应用事件的处理：SSE 流、工具结果、状态推送、会话创建等。
--
-- 从 @UI.Brick@ 拆出（351 行，本模块最大）。它是事件总线的汇聚点：调度层
-- 推来的每一类事件都在这里落到 AppState 上。
module UI.Brick.AppEvent
  ( handleAppEvent
  , refreshMode
  , ensurePending
  , appendDelta
  , appendReasoningDelta
  , addToolLine
  , flushPending
  , flushPendingAt
  , toCardStatus
  , renderToolEvent
  ) where

import Brick
import Brick.BChan
import Brick.Widgets.Center (centerLayer)
import Brick.Widgets.Border
import Brick.Widgets.Edit
import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar, tryPutMVar)
import Control.Concurrent.Async (async)
import Control.Monad (filterM, forM_, forever, unless, void, when)
import Control.Monad.IO.Class (liftIO)
import System.Timeout (timeout)
import Core.Clipboard (readClipboardText, saveClipboardImage)
import Core.Types
import Core.Bootstrap (ensureBackend)
import Bridge.Scheduler (SchedulerBridge, listPlugins, subscribeSessionEvents, subscribeSessionEventsWithTerminal, listSessions, createSession, deleteSession, sendMessage, sendMessageWithTarget, sendMessageWithTargetEffort, allowAlways, interruptSession, fetchSessionInfo, fetchAgents, SessionInfo(..), listProviders, saveProvider, probeProvider, removeProvider, ProviderProbe(..), listModels, planStep, approvePlan, denyPlan, submitPlan, decideStep, decidePlan, reportStep, fetchSessionMode, applySessionMode, renameSession, tagSession, fetchServiceStatus, denyPlanWithReason, fetchBalance, transcribeVoice, setSandboxConfig, fetchSandboxConfig, setSessionCwd, fetchPlan, setInUseProvider)
import Core.Replay (ReplayBlock(..), renderReplay)
import Core.RunState (stopAll, stopResultText)
import Core.Export (exportMarkdown, exportJson, defaultExportName)
import Core.TurnStats (Prices(..), turnSummary, estimateCost, hasPrices, isOffPeak, pricesForModel)
import UI.Event
import Core.SSE (SseNotice(..))
import Data.Aeson (Value(..), object, (.=), decode, encode)
import qualified Data.Aeson.Key as AK
import qualified Data.Aeson.KeyMap as KM
import qualified Data.Foldable as F
import qualified Data.ByteString.Lazy as BL
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Encoding.Error as TEE
import Core.SessionSummary (SessionSummary(..), pickLocalSession)
import Core.PlanStore (savePlanSnapshot)
import Core.ProjectStore (ensureProject, recordProjectSession)
import Core.Transcript (listLocalSessions, listLocalSessionsIn, loadTranscript, recordChunk, recordSession, recordToolEvent, recordUser)
import UI.Commands (executeCommand, runSettingsCommand, runLocalShell, resumeSessions, resumeMessages)
import UI.Commands.Registry
    ( Command(..), parseCommandWith, pickerItems, pickerItemsGrouped
    , groupKey, groupTitle, helpTextFor, registryHelp )
import UI.SettingsView (SettingsEntry(..), settingsEntries, filterEntries, isOverridden, maskSecret)
import UI.State
import UI.StatusInfo (StatusRow(..), collectStatusInfo)
import UI.StatsView (StatsBlock(..), buildStatsBlocks)
import UI.I18n (Lang(..), langName, parseLang, tr)
import Config.Settings (resolveConfig, saveConfig)
import Data.IORef (newIORef, readIORef)
import Data.List (intersperse, find)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isJust, isNothing, listToMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Data.Time.Clock (UTCTime, diffUTCTime, getCurrentTime)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Time.LocalTime (TimeZone, getCurrentTimeZone, utcToZonedTime)
import Data.Time.Format (formatTime, defaultTimeLocale)
import Graphics.Vty.Attributes
import Graphics.Vty.Config (defaultConfig)
import Graphics.Vty.CrossPlatform (mkVty)
import Graphics.Vty.Input.Events
import qualified Graphics.Vty as V
import Lens.Micro ((&), (.~), (%~), (^.))
import UI.Brick.Draw.Dialog (drawDialog, drawPalette, drawWizard, wizardSummary)
import UI.Selection (inSelRange)
import UI.Brick.DialogKeys
  ( chooseProvider, dialogAppend, dialogDelete, modifyTop, persistSelection
  , scrollBottom, selectSkill, withCommands )
import UI.Brick.Apply
  ( applyLanguage, applyTheme, modeAction, openSettingsPanel )
import UI.Brick.Toast (showToast)
import UI.Brick.Selection
  ( beginSel, extendSel, copySelectionText, finishSel, copyToClipboard
  , moveCardFocus, toggleFocusedCard, toolCardIds )
import UI.Brick.Input
  ( alwaysConfirmText, editorCursor, editorValue, promptIsEmpty )
import UI.Brick.SessionView
  ( blocksToMessages, localSessionLines, refreshSidebar, resumeSession )
import UI.Brick.Chat (handleChatWith)
import UI.Brick.ChatKeys (editDefaultKey, handleChatEnter, handleChatKey)
import UI.Brick.DialogActivate
  ( dialogActivate, handleDialogKey, refreshProviderEfforts
  , startProviderRemove, toggleProviderThinking )
import UI.Brick.Palette
  ( allPickerItems, movePalette, paletteItemsFor, refreshCompletion
  , refreshPalette, runPaletteItem )
import UI.Brick.InputOps
  ( clearView, insertPaste, pasteClipboardText, pasteImage, recordVoice
  , recordVoiceNote, steerDraft )
import UI.Brick.Slash (handleSlash)
import UI.Brick.Wizard
  ( commitWizard, finishWizard, invalidJson, refreshWizardInput
  , startWizard, startWizardPreset )
import UI.Brick.RunControl
  ( approveAndRun, decideApprovalNow, escapeHierarchy, escapeWithoutApproval
  , requestInterrupt, requestStopServices, runShellCommand, stopServicesAndHalt )
import UI.Brick.MessageOps (appendMsg, now, setWindowTitle)
import UI.Brick.Draw.Messages
  ( cardHidden, diffWidget, drawHome, drawInput, drawMessage, drawMessages
  , drawPending, drawPlanCard, drawToast, drawUI, messageBody, messageHeader
  , renderBlocks, renderToolBody, roleStyle )
import UI.Brick.Draw.Settings (drawSettingsPanel, settingsListMax, settingsRows, visibleRows)
import UI.Brick.Draw.Sidebar (drawCompletion, drawSidebar, sidebarDataFor)
import UI.Brick.Draw.Status
  ( drawStatus, modelLabel, pricesOf, statusLine
  , statusSandboxTag, statusClock, statusModelLine, statusGitLine, statusStatsLine )
import UI.Render.Footer (FooterLive(..), footerMetrics, parseMetrics, branchFromHead, statusFitsOneRow, wrapStatusLine)
import UI.Render.Spans
  ( SpanTok(..), boolText, diffAttrOf, fillLines, isCompactionMark
  , spanToks, splitAtWidth, spinnerFrame, todoGlyph, truncLine )
import UI.PasteFold (expandPastes, isLongPaste, pasteLabel)
import UI.TextWidth (takeCells)
import UI.TimeStamp (clockWithZone)
import UI.Render.Footer (footerHints)
import System.Directory (getCurrentDirectory, createDirectoryIfMissing, getHomeDirectory, doesFileExist, getTemporaryDirectory, removeFile, getFileSize)
import System.FilePath ((</>), takeDirectory, takeFileName)
import Numeric (showFFloat)
import Text.Read (readMaybe)
import System.Environment (getEnvironment, lookupEnv)
import System.IO (hFlush, hPutStr, stdout, stderr, openTempFile, hClose, hIsTerminalDevice)
import System.Process (readProcessWithExitCode)
import System.Exit (ExitCode(..))
import Control.Exception (IOException, SomeException, catch, try)
import Core.RunLog (logLine)
import UI.Render.Markdown (MdBlock(..), MdSpan(..), parseMarkdown)
import UI.Dialog
import UI.Render.ToolCard (ToolCard(..), ToolFold(..), ToolStatus(..), toolCardWithStatus, toggleFold)
import UI.ModelPrefs (orderedModels)
import UI.Render.Message (metaLine)
import UI.Render.Diff
    ( DiffClass(..), DiffLayout(..), DiffRow(..), diffClass, diffLayout, numberDiff
    , renderDiffRow, looksLikeDiff )
import UI.Layout
    ( SidebarState(..), SidebarRender(..), sidebarRender, messageWidth, toggleSidebar )
import UI.Render.Settings (computeStatsBlocks, renderStatsBlocks, renderStatusRows)
import UI.Render.Sidebar
    ( SidebarData(..), SidebarLine(..), sidebarLines, sidebarHint, agentTreeLines
    , truncateTo )
import UI.Completion
    ( Completion(..), CompletionState(..), completionPopup, moveCompletion
    , applySelected, defaultIndexOptions )
import UI.IndexCache (scanProjectCached)
import UI.Keys (LeaderAction(..), leaderResolve, leaderHelp, CtrlCAction(..), decideCtrlC, decideCtrlD)
import UI.Skills (Skill(..), scanSkills, skillDirs, parseSkillInvocation, skillTurn)
import UI.CustomCommands (CustomCommand(..), loadCustomCommands, renderCustomCommand)
import UI.Stash (Stash(..), emptyStash, stashPush, stashPop, stashEntries, loadStash, saveStash)
import UI.Frecency (Frecency(..), emptyFrecency, recordUse, rankItems, loadFrecency, saveFrecency)

handleAppEvent :: AppEvent -> EventM ResourceName AppState ()
handleAppEvent (EvSession result) = do
  case result of
    Right sid -> do
      st <- get
      -- Auto-created sessions are recorded silently so that the system
      -- message does not interleave between the user message and the reply.
      modify $ \s -> s { appSessionId = Just sid, appStatus = tr (appLang s) "Ready"
                       , appBusy = False
                       , appRoute = RouteSession
                       , appCacheNow = Nothing
                       , appCacheSum = (0, 0)
                       , appCacheTurns = 0
                       , appLastCost = 0
                       , appSessTokens = 0
                       , appLastDecodeTps = Nothing
                       , appFirstToken = Nothing }
      liftIO $ setWindowTitle ("trha · " <> T.take 8 (T.pack sid))
      liftIO $ refreshMode (appBridge st) sid (appChan st)
    Left err -> do
      lang <- gets appLang
      t <- liftIO now
      appendMsg (mkMsg "error" (tr lang "Session failed: " <> T.pack (show err)) t)
      modify $ \st -> st { appStatus = tr (appLang st) "Error", appBusy = False }
  scrollBottom
handleAppEvent (EvResponse result) = case result of
  Right chunk -> case chunk of
    ChunkDelta text    -> do
      -- The first delta ends the TTFT window; the pure-decode rate is measured
      -- from here, to the final usage.  Recorded once per turn.
      first <- gets appFirstToken
      when (isNothing first) $ do
        t <- liftIO getCurrentTime
        modify $ \s -> s { appFirstToken = Just t }
      appendDelta text
      scrollBottom
    ChunkToolCall n as -> addToolLine n as >> scrollBottom
    ChunkDone usage    -> do
      let real = usageTotalTokens usage > 0
          hit = usageCacheHitTokens usage
          miss = usageCacheMissTokens usage
          cacheSeen = real && hit + miss > 0
      st0 <- get
      t1 <- liftIO getCurrentTime
      let elapsed = maybe 0 (\t0 -> realToFrac (diffUTCTime t1 t0)) (appTurnStart st0)
                    :: Double
          tps = if real && elapsed > 0 && usageCompletionTokens usage > 0
                  then Just (fromIntegral (usageCompletionTokens usage) / elapsed)
                  else appLastTps st0
          -- Same numerator, but the clock starts at the first token: this is
          -- the number a provider's own dashboard reports as "t/s".
          decodeTps = case (appFirstToken st0, usageCompletionTokens usage) of
            (Just tFirst, n) | real && n > 0 ->
              let d = realToFrac (diffUTCTime t1 tFirst) :: Double
              in if d > 0.02 then Just (fromIntegral n / d) else Nothing
            _ -> appLastDecodeTps st0
      modify $ \s -> s { appLastUsage = Just (usageTotalTokens usage)
                       , appUsage = if real then Just usage else appUsage s
                       , appCacheNow = if cacheSeen then Just (hit, miss) else appCacheNow s
                       , appCacheSum = if cacheSeen
                                         then let (h0, m0) = appCacheSum s
                                              in (h0 + hit, m0 + miss)
                                         else appCacheSum s
                       , appCacheTurns = if cacheSeen
                                           then appCacheTurns s + 1
                                           else appCacheTurns s
                       , appCtxUsed = if usagePromptTokens usage > 0
                                        then Just (usagePromptTokens usage
                                                   + usageCompletionTokens usage)
                                        else appCtxUsed s
                       , appLastTps = tps
                       , appLastDecodeTps = decodeTps
                       , appCostSum = appCostSum s + estimateCost (pricesOf (appModel s) (appEffCfg s)) usage
                       , appLastCost = estimateCost (pricesOf (appModel s) (appEffCfg s)) usage
                       , appSessTokens = appSessTokens s + usageTotalTokens usage
                       , appFirstToken = Nothing
                       , appTurnStart = Nothing }
      flushPending (if real then Just usage else Nothing)
      st3 <- get
      let summary = turnSummary (pricesOf (appModel st3) (appEffCfg st3)) usage (usageReasoningTokens usage) t1
      appendMsg (mkMsg "stats" summary "")
      bell <- gets (configBell . appEffCfg)
      when bell $ liftIO (putStr "\a" >> hFlush stdout)
      scrollBottom
  Left err -> do
    flushPending Nothing -- keep whatever partial content already arrived
    t <- liftIO now
    let msg = T.pack (show err)
        staleSession = "not found" `T.isInfixOf` T.toLower msg
    lang0 <- gets appLang
    if staleSession
      then do
        -- The scheduler keeps sessions in memory; a restart (or a session
        -- deleted elsewhere) turns the id the TUI holds into a 404.  Drop it
        -- so the next message creates a fresh session instead of 404-ing.
        appendMsg (mkMsg "system"
          (tr lang0 "The session no longer exists on the scheduler; the next message creates a new one.") t)
        modify $ \st -> st { appSessionId = Nothing
                           , appStatus = tr (appLang st) "Session expired"
                           , appCacheNow = Nothing
                           , appCacheSum = (0, 0)
                           , appCacheTurns = 0
                           , appLastCost = 0
                           , appSessTokens = 0
                           , appLastDecodeTps = Nothing
                           , appFirstToken = Nothing }
      else appendMsg (mkMsg "error" ("Error: " <> msg) t)
    bell <- gets (configBell . appEffCfg)
    when bell $ liftIO (putStr "\a" >> hFlush stdout)
    modify $ \st -> st { appStatus = tr (appLang st) "Error", appBusy = False }
    scrollBottom
handleAppEvent (EvNotice notice) = case notice of
  ReasoningDelta text -> appendReasoningDelta text >> scrollBottom
  StepStarted rnd msgs tools -> do
    -- A new model round starts.  Close whatever the previous round left in
    -- the streaming block so the separator lands in the right place, then
    -- restore the turn's busy/status (flushPending is a turn-end action).
    st0 <- get
    when (isJust (appPending st0)) $ do
      flushPending Nothing
      modify $ \s -> s { appBusy = appBusy st0, appStatus = appStatus st0 }
    t <- liftIO now
    appendMsg (mkMsg "step"
      ("round " <> T.pack (show rnd) <> " · " <> T.pack (show msgs)
        <> " msgs · " <> T.pack (show tools) <> " tools") t)
    scrollBottom
  ContextCompacted trigger saved -> do
    t <- liftIO now
    appendMsg (mkMsg "compact"
      ("context compacted (" <> trigger <> ") · saved "
        <> T.pack (show saved) <> " tokens") t)
    scrollBottom
  RetryScheduled attempt delayMs reason -> do
    t <- liftIO now
    appendMsg (mkMsg "retry"
      ("retry " <> T.pack (show attempt) <> "/3 in "
        <> T.pack (show delayMs) <> "ms — " <> reason) t)
    scrollBottom

handleAppEvent (EvMode result) = case result of
  Right m -> do
    lang0 <- gets appLang
    -- 左侧 modeTag 已经显示模式名，appStatus 再写一遍就是「Read only ·
    -- 模式：Read only」。这里只确认「切换完成」。
    modify $ \s -> s { appMode = Just m
                     , appStatus = tr (appLang s) "Mode switched" }
    showToast (tr lang0 "Mode: " <> smLabel m)
  Left e  -> modify $ \s -> s { appStatus = "Mode: " <> T.pack (show e) }

handleAppEvent (EvSidebarInfo cwd files instrs) =
  modify $ \s -> s { appCwd = cwd, appFiles = files, appInstructions = instrs }

handleAppEvent (EvSessionInfo (Right info)) =
  modify $ \s -> s { appTodos = siTodos info, appGoal = siGoal info }
handleAppEvent (EvSessionInfo (Left _)) = return ()

handleAppEvent (EvAgents (Right as)) = modify $ \s -> s { appAgents = as }
handleAppEvent (EvAgents (Left _)) = return ()
handleAppEvent (EvServices lsp mcp) = modify $ \s -> s { appLsp = lsp, appMcp = mcp }
handleAppEvent (EvBalance (Right b)) = modify $ \s -> s { appBalance = Just b }
handleAppEvent (EvBalance (Left _)) = return ()
handleAppEvent (EvSandboxConfig (Right on)) = modify $ \s ->
  s { appSandbox = (appSandbox s) { ssEnabled = on } }
handleAppEvent (EvSandboxConfig (Left _)) = return ()

handleAppEvent (EvRecent xs) = modify $ \s -> s { appRecent = xs }

handleAppEvent (EvToast msg) = showToast msg

handleAppEvent (EvToastExpire t) =
  modify $ \s -> case appToast s of
    Just (_, t0) | t0 == t -> s { appToast = Nothing }
    _                      -> s

handleAppEvent (EvSessions result) = do
  lang <- gets appLang
  t <- liftIO now
  case result of
    Right [] -> appendMsg (mkMsg "system" (tr lang "No sessions.") t)
    Right sids -> do
      cwd <- liftIO getCurrentDirectory
      local <- liftIO (listLocalSessionsIn cwd)
      modify $ \s -> s { appDialogs = stackPush (DialogSessions local "" 0) (appDialogs s) }
      -- legacy ids row kept for parity with the REPL
      appendMsg (mkMsg "system" ((tr lang "Sessions:" <> "\n")
                       <> T.unlines (map (\s -> "  • " <> T.pack s) sids)) t)
    Left err -> appendMsg (mkMsg "system" (tr lang "Error: " <> T.pack (show err)) t)
  scrollBottom
handleAppEvent (EvModels result) = do
  lang <- gets appLang
  t <- liftIO now
  case result of
    Right [] -> appendMsg (mkMsg "system" (tr lang "No models available.") t)
    Right ms -> do
      st <- get
      case stackTop (appDialogs st) of
        Just (DialogModels _ _ _) ->
          modifyTop (const (DialogModels (orderedModels (appModelPrefs st) ms) "" 0))
        _ -> appendMsg (mkMsg "system" ((tr lang "Models:" <> "\n") <> T.unlines
                         (map (\m -> "  • " <> modelName m <> " — " <> modelDescription m) ms)) t)
    Left err -> do
      st <- get
      case stackTop (appDialogs st) of
        Just (DialogModels _ _ _) -> modify $ \s -> s { appDialogs = stackPop (appDialogs s) }
        _ -> return ()
      appendMsg (mkMsg "error" (tr lang "Error: " <> T.pack (show err)) t)
  scrollBottom
handleAppEvent (EvDeleted sid) = do
  lang <- gets appLang
  t <- liftIO now
  appendMsg (mkMsg "system" (tr lang "Deleted session: " <> T.pack sid) t)
  showToast (tr lang "Deleted session: " <> T.pack sid)
  scrollBottom
handleAppEvent (EvPlan result) = do
  t <- liftIO now
  case result of
    Right (PlanAwaiting preview) ->
      appendMsg (mkMsg "plan" ("⏸ " <> preview) t)
    Left err -> do
      appendMsg (mkMsg "error" (T.pack (show err)) t)
      modify $ \st -> st { appStatus = tr (appLang st) "Error", appBusy = False }
  scrollBottom
handleAppEvent (EvPlanState result) = do
  lang <- gets appLang
  t <- liftIO now
  case result of
    Right (pv, reply) -> do
      -- Mirror the kernel's plan to ~/.trha/plans/ so it survives the session.
      sid <- gets appSessionId
      forM_ sid $ \s -> void (liftIO (savePlanSnapshot (T.pack s) pv))
      modify $ \st -> st { appPlan = Just pv, appStatus = tr lang "Plan", appBusy = False }
      case reply of
        Just txt | not (T.null txt) -> appendMsg (mkMsg "assistant" txt t)
        _ -> pure ()
    Left err -> do
      appendMsg (mkMsg "error" (T.pack (show err)) t)
      modify $ \st -> st { appStatus = tr lang "Error", appBusy = False }
  scrollBottom

handleAppEvent (EvVerdict result) = do
  lang <- gets appLang
  t <- liftIO now
  case result of
    Right (PlanApproved reply) -> do
      appendMsg (mkMsg "assistant" reply t)
      modify $ \st -> st { appStatus = tr (appLang st) "Ready", appBusy = False
                         , appApproval = Nothing }
    Right PlanDenied -> do
      appendMsg (mkMsg "system" (tr lang "Plan denied.") t)
      modify $ \st -> st { appApproval = Nothing, appBusy = False }
    Left err -> do
      appendMsg (mkMsg "error" (T.pack (show err)) t)
      modify $ \st -> st { appStatus = tr (appLang st) "Error", appBusy = False }
  scrollBottom
handleAppEvent EvTick = do
  t <- liftIO getCurrentTime
  modify $ \s -> s { appNow = Just t }

handleAppEvent (EvStatusInfo rows) = do
  modify $ \s -> s { appSysRows = rows }
handleAppEvent (EvMetrics rows) = do
  modify $ \s -> s { appMetrics = rows }
handleAppEvent (EvGitStat t) = modify $ \s -> s { appGitStat = t }
handleAppEvent (EvTool result) = do
  lang <- gets appLang
  t <- liftIO now
  case result of
    Right ev -> do
      -- running events only update the status line; completed events
      -- become tool cards
      modify $ \st -> st { appStatus = tr (appLang st) "tool: " <> T.pack (teName ev) <> " " <> tr (appLang st) (statusTagOf (teStatus ev)) }
      -- a permission ask parks the turn: keep the tool identity for the
      -- approval dialog ("always" derives its rule pattern from it)
      when (case teStatus ev of
              ToolRunFailed err -> "REQUIRE_APPROVAL:" `T.isPrefixOf` err
              _                 -> False) $ do
        asked <- liftIO getCurrentTime
        modify $ \st -> st { appAskTool = Just (teName ev, teArgs ev)
                           , appAskAt = Just asked }
      case teStatus ev of
        ToolRunRunning -> do
          -- A long tool call used to be invisible until it finished: the card
          -- only existed once the closing event arrived. Open the card now and
          -- remember which message it is, so `end` can rewrite it.
          appendMsg (toolCardMsg ev t)
          st <- get
          -- `appendMsg` appends, so the message just added is the last one and
          -- its id is (length - 1); `listToMaybe` would hand back the oldest.
          let mid = length (appMessages st) - 1
          when (not (T.null (teCallId ev))) $
            modify $ \s -> s { appRunningTools =
              Map.insert (teCallId ev) mid (appRunningTools s) }
        _ -> do
          st <- get
          let running = Map.lookup (teCallId ev) (appRunningTools st)
          case running of
            Just mid -> do
              -- Rewrite the opening card in place: one call, one card.
              modify $ \s -> s
                { appMessages = map (\m -> if msgId m == mid then toolCardMsg ev t else m)
                                  (appMessages s)
                , appRunningTools = Map.delete (teCallId ev) (appRunningTools s)
                }
            Nothing -> appendMsg (toolCardMsg ev t)
    Left err -> do
      appendMsg (mkMsg "error" (tr lang "SSE: " <> T.pack (show err)) t)
      modify $ \st -> st { appStatus = tr (appLang st) "Error" }
  scrollBottom
handleAppEvent (EvToggleToolFold mid) = do
  -- Flip the fold state of the tool message with the given id.
  modify $ \s -> s { appFolds =
    Map.alter (Just . toggleFold . fromMaybe FoldCollapsed) mid (appFolds s) }
  scrollBottom
handleAppEvent (EvCtxSize cs) = do
  modify $ \s -> s { appCtxSize = Just cs }
handleAppEvent (EvTodos (Right ts)) = do
  modify $ \s -> s { appTodos = ts }
handleAppEvent (EvTodos (Left _)) = return ()
handleAppEvent (EvSessionTitle mt) = do
  modify $ \s -> s { appSessionTitle = mt }
handleAppEvent (EvCompletionIndex ix) = do
  modify $ \s -> s { appIndex = ix }
handleAppEvent (EvProviders (Right ps)) = do
  modify $ \s -> s { appProviders = ps }
  -- The dialog is pushed empty while the fetch is in flight; fill it in
  -- place so the user does not have to reopen it.
  st <- get
  case stackTop (appDialogs st) of
    Just (DialogProviders _ _) -> modifyTop (const (DialogProviders ps 0))
    _                          -> return ()
handleAppEvent (EvProviders (Left _)) = return ()
handleAppEvent (EvSkills skills) = do
  modify $ \s -> s { appSkills = skills }
handleAppEvent (EvProviderSaved (Right ps)) = do
  modify $ \s -> s { appProviders = ps
                   , appStatus = tr (appLang s) "Provider saved" }
  lang <- gets appLang
  showToast (tr lang "Provider saved")
handleAppEvent (EvProviderSaved (Left e)) = do
  modify $ \s -> s { appStatus = "Provider save failed: " <> T.pack (show e) }
handleAppEvent (EvFinalReply text) = do
  -- The step reply is authoritative: replace whatever the preview has
  -- accumulated (a dropped delta must not truncate the answer).
  st <- get
  t <- liftIO now
  let pm = fromMaybe (newPending t) (appPending st)
  modify $ \s -> s { appPending = Just pm { pmContent = text } }
  scrollBottom

-- | Tool-card message from a completed lifecycle event (with output
-- preview lines from the kernel tail).

refreshMode :: SchedulerBridge -> SessionId -> BChan AppEvent -> IO ()
refreshMode bridge sid chan =
  void $ async $ fetchSessionMode bridge sid >>= writeBChan chan . EvMode

-- | Tool-card ids in display order (hidden cards excluded, so focus never
-- lands on something the viewport does not draw).
-- | 工具卡焦点组见 UI.Brick.Selection。

-- | Ensure a streaming block is open for the current assistant reply.
ensurePending :: EventM ResourceName AppState ()
ensurePending = do
  st <- get
  case appPending st of
    Just _ -> return ()
    Nothing -> do
      t <- liftIO now
      modify $ \s -> s { appPending = Just (newPending t) }

-- | Append a text delta to the open assistant block.
appendDelta :: Text -> EventM ResourceName AppState ()
appendDelta text = do
  -- Deltas are a live preview only.  Once the authoritative reply has
  -- closed the turn (busy = False), a late stream event must not reopen a
  -- pending block that nothing will ever flush.
  busy <- gets appBusy
  when busy $ do
    ensurePending
    modify $ \s -> s { appPending =
      (\pm -> pm { pmContent = pmContent pm <> text }) <$> appPending s }

-- | Append a reasoning (thinking) delta.  Same late-event rule as text
-- deltas: only while the turn is live.
appendReasoningDelta :: Text -> EventM ResourceName AppState ()
appendReasoningDelta text = do
  busy <- gets appBusy
  when busy $ do
    ensurePending
    modify $ \s -> s { appPending = appendReasoning text <$> appPending s }

-- | Record a tool invocation in the open block.
addToolLine :: ToolName -> [Text] -> EventM ResourceName AppState ()
addToolLine name args = do
  ensurePending
  let inv = ToolInv name args
  modify $ \s -> s { appPending = (\pm -> pm { pmTools = inv : pmTools pm }) <$> appPending s }

-- | Close the streaming block and persist it as chat messages.  @musage@ is
-- this turn's usage echo (the model + token footer); Nothing on failure.
flushPending :: Maybe Usage -> EventM ResourceName AppState ()
flushPending musage = do
  t1 <- liftIO getCurrentTime
  flushPendingAt musage t1

flushPendingAt :: Maybe Usage -> UTCTime -> EventM ResourceName AppState ()
flushPendingAt musage t1 = do
  st <- get
  case appPending st of
    -- The turn is over even if no block was open (e.g. a duplicate terminal
    -- event): never leave the spinner running.
    Nothing -> modify $ \s -> s { appBusy = False }
    Just pm -> do
      let base = appNextMsgId st
          stampedFrom base0 ms = zipWith (\i m -> m { msgId = base0 + i }) [0 ..] ms
          meta = metaLine (appModel st) musage
          withMeta m
            | not (T.null meta) = m { msgMeta = Just meta }
            | otherwise = m
          toolMsgs = [ toolMsg "tool" (ToolCard (tiName inv) (tiArgs inv) Nothing Nothing [] "") (pmStart pm)
                     | inv <- reverse (pmTools pm) ]
          thinkText = flushThinking pm
          thinkSecs = case appTurnStart st of
            Just t0 -> max 0 (round (realToFrac (diffUTCTime t1 t0) :: Double))
            Nothing -> 0
          thinkLabel = "思考了 " <> T.pack (show thinkSecs) <> " 秒 (Ctrl+O)"
          thinkMsgs = [ (mkMsg "thinking" thinkText (pmStart pm)) { msgMeta = Just thinkLabel }
                      | not (T.null thinkText) ]
          textMsgs = [ withMeta (mkMsg "assistant" (T.strip (pmContent pm)) (pmStart pm))
                     | not (T.null (T.strip (pmContent pm)))
                     , not (isAwaitReply (pmContent pm)) ]
          -- A parked turn: the kernel's permission gate (ask rules) returned
          -- early with "awaiting_approval: <REQUIRE_APPROVAL: reason>". The
          -- partial stream is real content, so flush it, then lock the flow
          -- and open the approval dialog.
          isAwaitReply c = "awaiting_approval:" `T.isPrefixOf` c
          awaitMsg = case drop 1 [ T.strip (T.drop 18 c) | c <- [T.strip (pmContent pm)], isAwaitReply c ] of
            (m : _) -> m
            []      -> ""
          parked = isAwaitReply (T.strip (pmContent pm)) && not (T.null awaitMsg)
          (askName, askArgs) = fromMaybe ("", []) (appAskTool st)
      modify $ \s -> s { appMessages = appMessages s
                                      ++ stampedFrom base thinkMsgs
                                      ++ stampedFrom (base + length thinkMsgs) toolMsgs
                                      ++ stampedFrom (base + length thinkMsgs + length toolMsgs) textMsgs
                       , appNextMsgId = base + length thinkMsgs + length toolMsgs + length textMsgs
                       , appPending = Nothing
                       -- A finished turn is never busy: parked approvals
                       -- clear the spinner too, otherwise the input stays
                       -- locked on "Thinking..." after every normal reply.
                       , appBusy = False
                       , appApproval = if parked then Just awaitMsg else appApproval s
                       , appDialogs = if parked
                                        then stackPush (DialogApproval awaitMsg askName askArgs 0) (appDialogs s)
                                        else appDialogs s
                       , appStatus = if parked
                                       then tr (appLang s) "Awaiting approval..."
                                       else tr (appLang s) "Ready" }

-- | Async events from background workers
-- | handleAppEvent 见 UI.Brick.AppEvent。


statusTagOf :: ToolRunStatus -> Text
statusTagOf ToolRunRunning   = "running…"
statusTagOf ToolRunSucceeded = "✓"
statusTagOf (ToolRunFailed _) = "✗"

-- | Render a tool card with its status footer (message text).

toolCardMsg :: ToolEvent -> Text -> ChatMessage
toolCardMsg ev t = toolMsg "tool" card t
  where
    card = ToolCard (teName ev) (teArgs ev)
                    (Just (toCardStatus (teStatus ev))) (teDurationMs ev)
                    (maybe [] T.lines (teOutput ev))
                    (maybe "generic" tvCard (teView ev))

-- | Approve the pending step, run it as an ordinary agent turn, then report the
-- result.
--
-- The kernel only *releases* a step; running it is the host's job. The shell's
-- honest version of that job is asking the agent with the step's title, and
-- then telling the kernel how it went — otherwise the kernel's progress would
-- be a guess.
-- | approveAndRun 见 UI.Brick.RunControl。

-- | Status text for the footer/status line.
-- | statusTagOf 见 UI.Brick.AppEvent。


toCardStatus :: ToolRunStatus -> ToolStatus
toCardStatus s = case s of
  ToolRunRunning   -> ToolRunning
  ToolRunSucceeded -> ToolSucceeded
  ToolRunFailed e  -> ToolFailed e

-- | Dispatch submitted input: open the quick picker when a slash prefix is
-- ambiguous, otherwise run the command / send the chat message.
-- | handleSubmit 见 UI.Brick.ChatKeys。

-- | handleChat 见 UI.Brick.ChatKeys。

-- | expandFileReferences 见 UI.Brick.ChatKeys。


renderToolEvent :: ToolEvent -> Text
renderToolEvent ev =
  T.unlines (toolCardWithStatus (cardLabel ev) (teArgs ev)
              (toCardStatus (teStatus ev)) (teDurationMs ev))
  where
    -- DSH's `presentCall`: the tool says how this specific call should be
    -- labelled. Falls back to the tool name when the event carries no view,
    -- which is every tool today.
    cardLabel e = case teView e of
      Just v | not (T.null (tvTitle v)) -> tvTitle v
      _                                 -> T.pack (teName e)

-- | Map the wire status to the card status type.
-- | toCardStatus 见 UI.Brick.AppEvent。

-- | 设置面板组见 UI.Brick.KeyDispatch。

