{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | 认领计划与权限姿态类应用事件。
--
-- 从 "UI.Brick.AppEvent" 拆出（认领式分派）。这一组都围绕 appPlan /
-- appApproval / appMode 三个字段的推进。
module UI.Brick.AppEvent.Plan
  ( handlePlanEvent
  ) where

import Brick
import Brick.BChan
import Brick.Widgets.Border
import Brick.Widgets.Edit
import Control.Monad (forM_, void)
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
import Core.PlanStore (savePlanSnapshot)
import UI.Commands.Registry
    ( Command(..), parseCommandWith, pickerItems, pickerItemsGrouped
    , groupKey, groupTitle, helpTextFor, registryHelp )
import UI.SettingsView (SettingsEntry(..), settingsEntries, filterEntries, isOverridden, maskSecret)
import UI.State
import UI.StatusInfo (StatusRow(..), collectStatusInfo)
import UI.StatsView (StatsBlock(..), buildStatsBlocks)
import UI.I18n (Lang(..), langName, parseLang, tr)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Graphics.Vty.Attributes
import Graphics.Vty.Input.Events
import qualified Graphics.Vty as V
import Lens.Micro ((&), (.~), (%~), (^.))
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
import System.FilePath ((</>), takeDirectory, takeFileName)
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

-- | 认领 EvMode / EvPlan / EvPlanState / EvVerdict。
handlePlanEvent :: AppEvent -> Maybe (EventM ResourceName AppState ())
handlePlanEvent (EvMode result) = Just $ onModeResult result
handlePlanEvent (EvPlan result) = Just $ onPlanResult result
handlePlanEvent (EvPlanState result) = Just $ onPlanStateResult result
handlePlanEvent (EvVerdict result) = Just $ onVerdictResult result
handlePlanEvent _ = Nothing

onModeResult :: Either CLIError SessionMode -> EventM ResourceName AppState ()
onModeResult result = case result of
  Right m -> do
    lang0 <- gets appLang
    -- 左侧 modeTag 已经显示模式名，appStatus 再写一遍就是「Read only ·
    -- 模式：Read only」。这里只确认「切换完成」。
    modify $ \s -> s { appMode = Just m
                     , appStatus = tr (appLang s) "Mode switched" }
    showToast (tr lang0 "Mode: " <> smLabel m)
  Left e  -> modify $ \s -> s { appStatus = "Mode: " <> T.pack (show e) }

onPlanResult :: Either CLIError PlanSubmit -> EventM ResourceName AppState ()
onPlanResult result = do
  t <- liftIO now
  case result of
    Right (PlanAwaiting preview) ->
      appendMsg (mkMsg "plan" ("⏸ " <> preview) t)
    Left err -> do
      appendMsg (mkMsg "error" (T.pack (show err)) t)
      modify $ \st -> st { appStatus = tr (appLang st) "Error", appBusy = False }
  scrollBottom

onPlanStateResult :: Either CLIError (PlanView, Maybe Text) -> EventM ResourceName AppState ()
onPlanStateResult result = do
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

onVerdictResult :: Either CLIError PlanVerdict -> EventM ResourceName AppState ()
onVerdictResult result = do
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
