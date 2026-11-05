{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | 计划审批类斜杠命令：@/approve@、@/deny@。
--
-- 从 "UI.Brick.Slash" 拆出（认领式分派）。多步计划（phase=planning）走
-- decideStep/approveAndRun，单步批准走 approvePlan，两者的状态机不同。
module UI.Brick.Slash.Plan
  ( handlePlanSlash
  ) where

import Brick
import Brick.BChan
import Brick.Widgets.Border
import Brick.Widgets.Edit
import Control.Concurrent.Async (async)
import Control.Monad (void)
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
import Core.Transcript (recordUser)
import UI.Commands.Registry
    ( Command(..), parseCommandWith, pickerItems, pickerItemsGrouped
    , groupKey, groupTitle, helpTextFor, registryHelp )
import UI.SettingsView (SettingsEntry(..), settingsEntries, filterEntries, isOverridden, maskSecret)
import UI.State
import UI.StatusInfo (StatusRow(..), collectStatusInfo)
import UI.StatsView (StatsBlock(..), buildStatsBlocks)
import UI.I18n (Lang(..), langName, parseLang, tr)
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Graphics.Vty.Attributes
import Graphics.Vty.Input.Events
import qualified Graphics.Vty as V
import Lens.Micro ((&), (.~), (%~), (^.))
import UI.Brick.DialogKeys
  ( chooseProvider, dialogAppend, dialogDelete, modifyTop, persistSelection
  , scrollBottom, withCommands )
import UI.Brick.Apply
  ( applyLanguage, applyTheme, modeAction, openSettingsPanel )
import UI.Brick.Selection
  ( beginSel, extendSel, copySelectionText, finishSel, copyToClipboard )
import UI.Brick.Input
  ( alwaysConfirmText, editorCursor, editorValue, promptIsEmpty )
import UI.Brick.SessionView
  ( blocksToMessages, localSessionLines, refreshSidebar, resumeSession )
import UI.Brick.Slash.Ctx (CmdCtx(..))
import UI.Brick.RunControl
  ( approveAndRun, decideApprovalNow, escapeHierarchy, escapeWithoutApproval
  , requestInterrupt, requestStopServices, runShellCommand, stopServicesAndHalt )
import UI.Brick.MessageOps (appendMsg)
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
import System.Exit (ExitCode(..))
import UI.Render.Markdown (MdBlock(..), MdSpan(..), parseMarkdown)
import UI.Dialog
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
import UI.ModelPrefs (ModelPrefs(..), emptyModelPrefs, toggleFavorite, recordRecent, orderedModels, loadModelPrefs, saveModelPrefs)
import UI.InputHistory (HistState(..), emptyHistState, histUp, histDown, histCommit, loadHistory, appendHistory)
import UI.Render.Picker (PickerItem(..), filterItems, maxVisible, moveSelection, queryAppend, queryDelete, windowRange, buildPalette, isSection, firstSelectable)
import UI.ProviderPresets (Preset(..), presets, prePopular)
import UI.Render.ToolCard (ToolStatus(..), ToolCard(..), ToolFold(..), toggleFold, toolCardWithStatus, toolStatusLine, cardWidth)
import qualified UI.TextWidth as TW
import UI.Theme

handlePlanSlash :: CmdCtx -> Maybe (EventM ResourceName AppState ())
handlePlanSlash cx = case cxCmd cx of
  "/approve" -> Just $ slashApprove cx
  "/deny" -> Just $ slashDeny cx
  _ | (cxCmd cx) == "/plan" -> Just $ slashPlanUsage cx
  _ | "/plan " `T.isPrefixOf` (cxCmd cx) -> Just $ slashPlanSubmit cx
  _ | (cxCmd cx) `elem` ["/skip", "/reject", "/abandon"] -> Just $ slashPlanVerdict cx
  _ -> Nothing

slashApprove :: CmdCtx -> EventM ResourceName AppState ()
slashApprove cx = do
  cur <- gets appSessionId
  plan <- gets appPlan
  case cur of
    Nothing -> appendMsg (mkMsg "system" "No session yet — use /new or send a message first." (cxTime cx))
    Just sid -> case plan of
      Just pv | pvPhase pv == "planning" -> do
        -- multi-step plan: release the pending step, run it, report back
        modify $ \s -> s { appBusy = True, appStatus = "Approving step..." }
        void $ liftIO $ async $
          writeBChan (cxChan cx) . EvPlanState =<< approveAndRun (cxBridge cx) sid
      _ -> do
        modify $ \s -> s { appBusy = True, appStatus = "Executing plan..." }
        void $ liftIO $ async $ do
          r <- approvePlan (cxBridge cx) sid
          writeBChan (cxChan cx) (EvVerdict r)

slashDeny :: CmdCtx -> EventM ResourceName AppState ()
slashDeny cx = do
  cur <- gets appSessionId
  let reason = T.strip (T.drop 5 (cxInput cx))
  case cur of
    Nothing -> appendMsg (mkMsg "system" "No session yet — use /new or send a message first." (cxTime cx))
    Just sid -> do
      -- 有 planning 计划时拒绝待审批步骤；没有就直接说清楚，
      -- 不要拿内核的 400 "No pending approval" 当反馈。
      plan <- liftIO (fetchPlan (cxBridge cx) sid)
      case plan of
        Right pv | pvPhase pv == "planning" -> do
          void $ liftIO $ async $ do
            r <- decideStep (cxBridge cx) sid "reject"
            writeBChan (cxChan cx) (EvPlanState (fmap ((, Nothing)) r))
        _ -> appendMsg (mkMsg "system"
               (tr (cxLang cx) "Nothing to deny — no pending plan or approval.") (cxTime cx))

slashPlanUsage :: CmdCtx -> EventM ResourceName AppState ()
slashPlanUsage cx = do
      appendMsg (mkMsg "system" (tr (cxLang cx) "Usage: /plan <what to do>") (cxTime cx))

slashPlanSubmit :: CmdCtx -> EventM ResourceName AppState ()
slashPlanSubmit cx = do
      let planText = T.strip (T.drop 6 (cxInput cx))
          steps = splitPlanSteps planText
      cur <- gets appSessionId
      case cur of
        Nothing ->
          appendMsg (mkMsg "system" "No session yet — use /new or send a message first." (cxTime cx))
        -- Two or more steps → a real multi-step plan, approved one step at a
        -- time. A single line keeps the single-command gate.
        Just sid | length steps >= 2 -> do
          appendMsg (mkMsg "user" planText (cxTime cx))
          modify $ \s2 -> s2 { appBusy = True, appStatus = "Planning..." }
          void $ liftIO $ async $ do
            recordUser sid planText
            r <- submitPlan (cxBridge cx) sid steps
            writeBChan (cxChan cx) (EvPlanState (fmap ((, Nothing)) r))
        Just sid -> do
          appendMsg (mkMsg "user" planText (cxTime cx))
          modify $ \s2 -> s2 { appBusy = True, appStatus = "Awaiting approval..." }
          void $ liftIO $ async $ do
            recordUser sid planText
            r <- planStep (cxBridge cx) sid planText
            writeBChan (cxChan cx) (EvPlan r)

slashPlanVerdict :: CmdCtx -> EventM ResourceName AppState ()
slashPlanVerdict cx = do
      cur <- gets appSessionId
      case cur of
        Nothing ->
          appendMsg (mkMsg "system" "No session yet — use /new or send a message first." (cxTime cx))
        Just sid -> do
          -- 没有待审批计划时先说清楚，不要拿一条内核 502 当反馈。
          plan <- liftIO (fetchPlan (cxBridge cx) sid)
          case plan of
            Right pv | pvPhase pv == "planning" -> do
              let action = T.drop 1 (cxCmd cx)
              modify $ \s2 -> s2 { appBusy = True, appStatus = "Plan decision..." }
              void $ liftIO $ async $ do
                r <- decideStep (cxBridge cx) sid action
                writeBChan (cxChan cx) (EvPlanState (fmap ((, Nothing)) r))
            _ -> appendMsg (mkMsg "system"
                   (tr (cxLang cx) "No pending plan — submit one with /plan first.") (cxTime cx))
