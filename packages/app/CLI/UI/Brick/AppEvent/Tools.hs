{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | 认领工具类应用事件：工具生命周期（running/completed/failed）与卡片折叠切换。
--
-- 从 "UI.Brick.AppEvent" 拆出（认领式分派）。EvTool 是除 SSE 增量外最复杂的
-- 一条：running 事件只更新状态行并**提前开卡**（长工具调用不再隐形），
-- completed 事件把卡片就地改写，权限询问则停住回合等审批。
module UI.Brick.AppEvent.Tools
  ( handleToolEvent
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
import UI.Brick.AppEvent.Stream (handleStreamEvent)
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

-- | 认领 EvTool / EvToggleToolFold。
handleToolEvent :: AppEvent -> Maybe (EventM ResourceName AppState ())
handleToolEvent (EvTool result) = Just $ do
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
        ToolRunRunning -> onToolRunning ev t
        _              -> onToolFinished ev t
    Left err -> do
      appendMsg (mkMsg "error" (tr lang "SSE: " <> T.pack (show err)) t)
      modify $ \st -> st { appStatus = tr (appLang st) "Error" }
  scrollBottom
handleToolEvent (EvToggleToolFold mid) = Just $ do
  -- Flip the fold state of the tool message with the given id.
  modify $ \s -> s { appFolds =
    Map.alter (Just . toggleFold . fromMaybe FoldCollapsed) mid (appFolds s) }
  scrollBottom
handleToolEvent _ = Nothing

-- | 工具开始运行：先开卡并记住消息 id，完成事件到达时就地改写。
onToolRunning :: ToolEvent -> Text -> EventM ResourceName AppState ()
onToolRunning ev t = do
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

-- | 工具结束：有对应开卡就改写它，否则追加一张新卡。
onToolFinished :: ToolEvent -> Text -> EventM ResourceName AppState ()
onToolFinished ev t = do
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
