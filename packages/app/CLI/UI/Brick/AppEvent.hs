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
import Data.Foldable (msum)
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
import UI.Brick.AppEvent.Model (handleModelEvent)
import UI.Brick.AppEvent.Plan (handlePlanEvent)
import UI.Brick.AppEvent.Session (handleSessionEvent)
import UI.Brick.AppEvent.Sidebar (handleSidebarEvent)
import UI.Brick.AppEvent.Status (handleStatusEvent)
import UI.Brick.AppEvent.Toast (handleToastEvent)
import UI.Brick.Stream
  ( addToolLine, appendDelta, appendReasoningDelta, ensurePending, flushPending
  , flushPendingAt, refreshMode )
import UI.Brick.ToolCardMsg
  ( renderToolEvent, statusTagOf, toCardStatus, toolCardMsg )
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
-- | 认领式分派：Sidebar/Status/Toast 三个域先试，未命中再落到下方各等式。
handleAppEvent ev = fromMaybe (pure ()) $
  msum [ handleModelEvent ev, handlePlanEvent ev, handleSessionEvent ev, handleSidebarEvent ev
         , handleStatusEvent ev, handleToastEvent ev ]

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
