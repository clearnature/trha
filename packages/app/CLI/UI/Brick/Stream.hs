{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | 流式处理组：SSE 增量累积与落盘（助手文本、推理文本、工具行），
-- 以及把助手消息一次性 flush 进消息区。
--
-- 从 "UI.Brick.AppEvent" 拆出：这些函数只与 PendingMsg/消息区有关，
-- 与「哪类事件触发了它们」无关。
module UI.Brick.Stream
  ( refreshMode, ensurePending, appendDelta, appendReasoningDelta
  , addToolLine, flushPending, flushPendingAt
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
