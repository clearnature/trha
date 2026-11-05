{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | 认领流式响应类应用事件：增量块、侧信道通知、回合终稿。
--
-- 从 "UI.Brick.AppEvent" 拆出（认领式分派）。这一组是 SSE 流的三个入口，
-- 与 "UI.Brick.Stream"（累积/落盘的具体操作）分工：这里决定「收到什么该做什么」，
-- 那里实现「怎么累积」。
module UI.Brick.AppEvent.Stream
  ( handleStreamEvent
  ) where

import Brick
import Brick.BChan
import Brick.Widgets.Border
import Brick.Widgets.Edit
import Control.Monad (when)
import Control.Monad.IO.Class (liftIO)
import Core.Types
import Bridge.Scheduler (SchedulerBridge, listPlugins, subscribeSessionEvents, subscribeSessionEventsWithTerminal, listSessions, createSession, deleteSession, sendMessage, sendMessageWithTarget, sendMessageWithTargetEffort, allowAlways, interruptSession, fetchSessionInfo, fetchAgents, SessionInfo(..), listProviders, saveProvider, probeProvider, removeProvider, ProviderProbe(..), listModels, planStep, approvePlan, denyPlan, submitPlan, decideStep, decidePlan, reportStep, fetchSessionMode, applySessionMode, renameSession, tagSession, fetchServiceStatus, denyPlanWithReason, fetchBalance, transcribeVoice, setSandboxConfig, fetchSandboxConfig, setSessionCwd, fetchPlan, setInUseProvider)
import Core.Replay (ReplayBlock(..), renderReplay)
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
import UI.Commands.Registry
    ( Command(..), parseCommandWith, pickerItems, pickerItemsGrouped
    , groupKey, groupTitle, helpTextFor, registryHelp )
import UI.SettingsView (SettingsEntry(..), settingsEntries, filterEntries, isOverridden, maskSecret)
import UI.State
import UI.StatusInfo (StatusRow(..), collectStatusInfo)
import UI.StatsView (StatsBlock(..), buildStatsBlocks)
import UI.I18n (Lang(..), langName, parseLang, tr)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isJust, isNothing)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import Graphics.Vty.Attributes
import Graphics.Vty.Input.Events
import qualified Graphics.Vty as V
import Lens.Micro ((&), (.~), (%~), (^.))
import UI.Brick.DialogKeys
  ( chooseProvider, dialogAppend, dialogDelete, modifyTop, persistSelection
  , scrollBottom, selectSkill, withCommands )
import UI.Brick.Apply
  ( applyLanguage, applyTheme, modeAction, openSettingsPanel )
import UI.Brick.Selection
  ( beginSel, extendSel, copySelectionText, finishSel, copyToClipboard
  , moveCardFocus, toggleFocusedCard, toolCardIds )
import UI.Brick.Input
  ( alwaysConfirmText, editorCursor, editorValue, promptIsEmpty )
import UI.Brick.SessionView
  ( blocksToMessages, localSessionLines, refreshSidebar, resumeSession )
import UI.Brick.Stream
  ( addToolLine, appendDelta, appendReasoningDelta, ensurePending, flushPending
  , flushPendingAt, refreshMode )
import UI.Brick.ToolCardMsg
  ( renderToolEvent, statusTagOf, toCardStatus, toolCardMsg )
import UI.Brick.DialogActivate
  ( dialogActivate, handleDialogKey, refreshProviderEfforts
  , startProviderRemove, toggleProviderThinking )
import UI.Brick.Palette
  ( allPickerItems, movePalette, paletteItemsFor, refreshCompletion
  , refreshPalette, runPaletteItem )
import UI.Brick.InputOps
  ( clearView, insertPaste, pasteClipboardText, pasteImage, recordVoice
  , recordVoiceNote, steerDraft )
import UI.Brick.Wizard
  ( commitWizard, finishWizard, invalidJson, refreshWizardInput
  , startWizard, startWizardPreset )
import UI.Brick.RunControl
  ( approveAndRun, decideApprovalNow, escapeHierarchy, escapeWithoutApproval
  , requestInterrupt, requestStopServices, runShellCommand, stopServicesAndHalt )
import UI.Brick.MessageOps (appendMsg, now)
import UI.Brick.Draw.Messages
  ( cardHidden, diffWidget, drawHome, drawInput, drawMessage, drawMessages
  , drawPending, drawPlanCard, drawToast, drawUI, messageBody, messageHeader
  , renderBlocks, renderToolBody, roleStyle )
import UI.Brick.Draw.Status
  ( drawStatus, modelLabel, pricesOf, statusLine
  , statusSandboxTag, statusClock, statusModelLine, statusGitLine, statusStatsLine )
import UI.Render.Footer (FooterLive(..), footerMetrics, parseMetrics, branchFromHead, statusFitsOneRow, wrapStatusLine)
import UI.Render.Spans
  ( SpanTok(..), boolText, diffAttrOf, fillLines, isCompactionMark
  , spanToks, splitAtWidth, spinnerFrame, todoGlyph, truncLine )
import System.FilePath ((</>))
import System.IO (hFlush, stdout)
import System.Exit (ExitCode(..))
import UI.Render.Markdown (MdBlock(..), MdSpan(..), parseMarkdown)
import UI.Dialog
import UI.Render.ToolCard (ToolCard(..), ToolFold(..), ToolStatus(..), toolCardWithStatus, toggleFold)
import UI.Render.Diff
    ( DiffClass(..), DiffLayout(..), DiffRow(..), diffClass, diffLayout, numberDiff
    , renderDiffRow, looksLikeDiff )
import UI.Layout
    ( SidebarState(..), SidebarRender(..), sidebarRender, messageWidth, toggleSidebar )
import UI.Render.Sidebar
    ( SidebarData(..), SidebarLine(..), sidebarLines, sidebarHint, agentTreeLines
    , truncateTo )
import UI.Completion
    ( Completion(..), CompletionState(..), completionPopup, moveCompletion
    , applySelected, defaultIndexOptions )
import UI.Keys (LeaderAction(..), leaderResolve, leaderHelp, CtrlCAction(..), decideCtrlC, decideCtrlD)
import UI.Skills (Skill(..), scanSkills, skillDirs, parseSkillInvocation, skillTurn)
import UI.CustomCommands (CustomCommand(..), loadCustomCommands, renderCustomCommand)
import UI.Stash (Stash(..), emptyStash, stashPush, stashPop, stashEntries, loadStash, saveStash)
import UI.Frecency (Frecency(..), emptyFrecency, recordUse, rankItems, loadFrecency, saveFrecency)

-- | 认领 EvResponse / EvNotice / EvFinalReply。
handleStreamEvent :: AppEvent -> Maybe (EventM ResourceName AppState ())
handleStreamEvent (EvResponse result) = Just $ onStreamResponse result
handleStreamEvent (EvNotice notice) = Just $ onStreamNotice notice
handleStreamEvent (EvFinalReply text) = Just $ onFinalReply text
handleStreamEvent _ = Nothing

onStreamResponse result = case result of
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
    ChunkDone usage    -> finishTurn usage
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

onStreamNotice notice = case notice of
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

onFinalReply text = do
  -- The step reply is authoritative: replace whatever the preview has
  -- accumulated (a dropped delta must not truncate the answer).
  st <- get
  t <- liftIO now
  let pm = fromMaybe (newPending t) (appPending st)
  modify $ \s -> s { appPending = Just pm { pmContent = text } }
  scrollBottom

-- | Tool-card message from a completed lifecycle event (with output
-- preview lines from the kernel tail).

-- | 回合收尾：把累积的用量/耗时/缓存换算成统计字段，落盘并输出摘要。
-- 从 handleStreamEvent 的 ChunkDone 分支提取——它是一个完整业务动作，
-- 与「哪类 chunk 进来了」无关。
finishTurn :: Usage -> EventM ResourceName AppState ()
finishTurn usage = do
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
