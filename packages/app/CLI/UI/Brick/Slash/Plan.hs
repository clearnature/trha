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
import Bridge.Scheduler (SchedulerBridge, listPlugins, subscribeSessionEvents, subscribeSessionEventsWithTerminal, listSessions, createSession, deleteSession, sendMessage, sendMessageWithTarget, sendMessageWithTargetEffort, allowAlways, interruptSession, fetchSessionInfo, fetchAgents, SessionInfo(..), listProviders, saveProvider, probeProvider, removeProvider, ProviderProbe(..), listModels, planStep, approvePlan, denyPlan, submitPlan, decideStep, decidePlan, reportStep, fetchSessionMode, applySessionMode, renameSession, tagSession, fetchServiceStatus, denyPlanWithReason, fetchBalance, transcribeVoice, setSandboxConfig, fetchSandboxConfig, setSessionCwd, fetchPlan, setInUseProvider, forkSession)
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
import Core.Transcript (loadTranscript, recordUser)
import Data.List (sortBy)
import Data.Ord (comparing, Down (Down))
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
import System.Directory (getCurrentDirectory, getHomeDirectory, listDirectory, doesDirectoryExist)
import UI.Commands.Helpers (findFilesNamed, snapshotBase)
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
  "/rewind" -> Just $ slashRewindPick cx
  "/restore" -> Just $ slashRestorePick cx
  -- /deny <reason>：按首词认领（cxCmd 是整条输入的小写），理由由 slashDeny
  -- 从输入解析——否则 "/deny xxx" 会漏到文本兜底、DenyWith 丢失。
  _ | (cxCmd cx) == "/deny" || "/deny " `T.isPrefixOf` (cxCmd cx) -> Just $ slashDeny cx
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

-- | @/rewind@（无参）→ 轮次选择器：列出本会话的 user turn，选中即
-- forkSession 回到该轮并切到新会话（EvCommandDone 回填状态）。
slashRewindPick :: CmdCtx -> EventM ResourceName AppState ()
slashRewindPick cx = do
  cur <- gets appSessionId
  let t = cxTime cx
  case cur of
    Nothing -> appendMsg (mkMsg "system" "No session yet — use /new or send a message first." t)
    Just sid -> do
      let act i = do
            r <- forkSession (cxBridge cx) sid (Just i)
            case r of
              Right newSid -> writeBChan (cxChan cx) (EvCommandDone
                               (Just ("Rewound to turn " <> T.pack (show i) <> ": " <> T.pack newSid))
                               (Just newSid))
              Left e -> writeBChan (cxChan cx) (EvToast (T.pack (show e)))
      -- 转录是本地文件，同步读取（与 /export 同先例）；小会话毫秒级。
      vals <- liftIO (loadTranscript sid)
      let blocks = renderReplay vals
          turns = [ (k, T.take 60 (T.strip (rbContent b)))
                  | (k, b) <- zip [1 :: Int ..] blocks
                  , rbRole b == "user", not (T.null (T.strip (rbContent b))) ]
      if null turns
        then liftIO $ writeBChan (cxChan cx) (EvToast "No user turns to rewind to.")
        else modify $ \s -> s { appDialogs = stackPush (DialogPick "Rewind to turn" turns (PickAction act) 0) (appDialogs s) }

-- | @/restore@（无参）→ 快照选择器：列 ~/.trha/file-history 最近 20 份，
-- 选中即按 basename 回找写回（复用 snapshotBase / findFilesNamed）。
slashRestorePick :: CmdCtx -> EventM ResourceName AppState ()
slashRestorePick cx = do
  home <- liftIO getHomeDirectory
  let dir = home </> ".trha" </> "file-history"
      chan = cxChan cx
      t = cxTime cx
  present <- liftIO (doesDirectoryExist dir)
  names <- if present then liftIO (sortBy (comparing (Data.Ord.Down)) <$> listDirectory dir) else pure []
  if not present || null names
    then appendMsg (mkMsg "system" (tr (cxLang cx) "No file history yet (~/.trha/file-history).") t)
    else do
      let act i = do
            names' <- sortBy (comparing (Data.Ord.Down)) <$> listDirectory dir
            if i >= 1 && i <= length names'
              then do
                let snap = names' !! (i - 1)
                case snapshotBase snap of
                  Nothing -> writeBChan chan (EvToast ("Unrecognised snapshot: " <> T.pack snap))
                  Just base -> do
                    cwd <- getCurrentDirectory
                    hits <- findFilesNamed cwd base
                    case hits of
                      [target] -> do
                        body <- TIO.readFile (dir </> snap)
                        TIO.writeFile target body
                        writeBChan chan (EvToast ("Restored " <> T.pack snap <> " -> " <> T.pack target))
                      _ -> writeBChan chan (EvToast
                             ("candidates for " <> T.pack base <> ": " <> T.pack (show (length hits))
                              <> " — cd into the right tree and retry"))
              else writeBChan chan (EvToast "snapshot pick failed")
          -- 快照目录列表是本地 IO，同步读（与 /clear-attachments 同先例）。
          items = zip [1 ..] (map T.pack (take 20 names))
      modify $ \s -> s { appDialogs = stackPush (DialogPick "Restore snapshot" items (PickAction act) 0) (appDialogs s) }

slashDeny :: CmdCtx -> EventM ResourceName AppState ()
slashDeny cx = do
  cur <- gets appSessionId
  let reason = T.strip (T.drop 5 (cxInput cx))
  case cur of
    Nothing -> appendMsg (mkMsg "system" "No session yet — use /new or send a message first." (cxTime cx))
    Just sid
      -- 带理由：denyPlanWithReason（计划级拒绝并附理由，与 REPL DenyWith 同语义）。
      | not (T.null reason) -> void $ liftIO $ async $ do
          r <- denyPlanWithReason (cxBridge cx) sid reason
          writeBChan (cxChan cx) (EvToast $ case r of
            Right PlanDenied        -> tr (cxLang cx) "Plan denied."
            Right (PlanApproved _) -> tr (cxLang cx) "Plan was approved (unexpected)."
            Left err                -> T.pack (show err))
      -- 无理由：planning 阶段拒绝待审批步骤；两者都没有 → 如实提示，
      -- 不要拿内核的 400 "No pending approval" 当反馈。
      | otherwise -> do
          plan <- liftIO (fetchPlan (cxBridge cx) sid)
          case plan of
            Right pv | pvPhase pv == "planning" -> void $ liftIO $ async $ do
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
