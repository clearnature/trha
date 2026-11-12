{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | 对话框激活：栈顶对话框被选中时执行的动作。
--
-- 12 个 Dialog 构造子各一分支——选模型/会话/命令/技能/预设/供应商/主题/
-- 语言/沙箱/审批/确认。从 @UI.Brick@ 拆出。
module UI.Brick.DialogActivate
  ( dialogActivate
  , handleDialogKey
  , toggleProviderThinking
  , startProviderRemove
  , refreshProviderEfforts
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
import UI.Theme (themeName)
import UI.Commands.Registry
    ( Command(..), parseCommandWith, pickerItems, pickerItemsGrouped
    , groupKey, groupTitle, helpTextFor, registryHelp )
import UI.SettingsView (SettingsEntry(..), settingsEntries, filterEntries, isOverridden, maskSecret)
import UI.State
import UI.StatusInfo (StatusRow(..), collectStatusInfo)
import UI.StatsView (StatsBlock(..), buildStatsBlocks)
import UI.I18n (Lang(..), langName, parseLang, tr)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isJust)
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
import UI.Brick.Selection
  ( beginSel, extendSel, copySelectionText, finishSel, copyToClipboard )
import UI.Brick.Input
  ( alwaysConfirmText, editorCursor, editorValue, promptIsEmpty )
import UI.Brick.SessionView
  ( blocksToMessages, localSessionLines, refreshSidebar, resumeSession )
import UI.Brick.Slash (handleSlash)
import UI.Brick.Wizard
  ( commitWizard, finishWizard, invalidJson, refreshWizardInput
  , startWizard, startWizardPreset )
import UI.Brick.RunControl
  ( approveAndRun, decideApprovalNow, escapeHierarchy, escapeWithoutApproval
  , requestInterrupt, requestStopServices, runShellCommand, stopServicesAndHalt )
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

dialogActivate :: EventM ResourceName AppState ()
dialogActivate = do
  st <- get
  case stackTop (appDialogs st) of
    Nothing -> return ()
    Just d -> do
      modify $ \s -> s { appDialogs = stackPop (appDialogs s) }
      case d of
        DialogModels _ _ sel -> case drop sel (dialogModelsItems d) of
          (m : _) -> do
            modify $ \s -> s { appModel = modelName m }
            st2 <- get
            let prefs' = recordRecent (modelName m) (appModelPrefs st2)
            liftIO (saveModelPrefs prefs')
            modify $ \s -> s { appModelPrefs = prefs' }
          []      -> return ()
        DialogSessions _ _ sel -> case drop sel (dialogSessionsItems d) of
          (s : _) -> resumeSession (T.pack (ssId s))
          []      -> return ()
        DialogCommands _ _ sel -> case drop sel (dialogCommandsItems d) of
          (item : _) | not (isSection item) -> handleSlash (piId item)
          _                                 -> return ()
        DialogProviders ps sel -> case drop sel ps of
          (p : _) -> chooseProvider p
          []      -> return ()
        DialogPresets ps sel -> case drop sel ps of
          (p : _) -> startWizardPreset p
          []      -> return ()
        DialogSkills _ _ sel -> case drop sel (dialogSkillsItems d) of
          (sk : _) -> selectSkill (skName sk)
          []       -> return ()
        DialogAgents as sel -> case drop sel as of
          (a : _) -> resumeSession (aeId a)
          []      -> return ()
        DialogThemes ts sel -> case drop sel ts of
          (t : _) -> applyTheme (themeName t)
          []      -> return ()
        DialogLanguages ls sel -> case drop sel ls of
          (l : _) -> applyLanguage l
          []      -> return ()
        DialogApproval _ name args sel ->
          case drop sel (approvalOptions name args) of
            (ApprovalOnce : _)   -> decideApprovalNow True
            (ApprovalAlways : _) -> modifyTop $ \_ ->
              DialogConfirm (alwaysConfirmText (appLang st) name args) 0
            _                    -> decideApprovalNow False
        DialogSandbox ss sel -> do
          st <- get
          let ss' = sandboxApply sel ss
          modify $ \s0 -> s0 { appSandbox = ss' }
          void $ liftIO $ async $ do
            r <- setSandboxConfig (appBridge st) (ssEnabled ss')
                   (ssPolicy ss')
                   (if ssNetwork ss' then "allow:*" else "off")
                   (ssScratch ss')
            case r of
              Left e -> writeBChan (appChan st) (EvToast ("sandbox: " <> T.pack (show e)))
              Right () -> writeBChan (appChan st) (EvToast "sandbox config saved")
        DialogConfirm _ sel -> case sel of
          0 -> do
            st2 <- get
            if appPendingStop st2
              then stopServicesAndHalt
              else case (appPendingProviderRemove st2, appPendingDelete st2, appPendingConfirm st2) of
                (Just pname, _, _) -> do
                  modify $ \s -> s { appDialogs = stackPop (appDialogs s)
                                   , appPendingProviderRemove = Nothing
                                   , appStatus = tr (appLang s) "Removing..." }
                  let bridge = appBridge st2
                      chan   = appChan st2
                  void $ liftIO $ async $ do
                    r <- removeProvider bridge pname
                    writeBChan chan (case r of
                      Right ps -> EvProviders (Right ps)   -- registry refresh
                      Left e   -> EvToast (T.pack ("Error: " <> show e)))
                (Nothing, Just sid, _) -> do
                  modify $ \s -> s { appDialogs = stackPop (appDialogs s)
                                   , appPendingDelete = Nothing
                                   , appStatus = tr (appLang s) "Deleting..." }
                  let bridge = appBridge st2
                      chan = appChan st2
                  void $ liftIO $ async $ do
                    r <- deleteSession bridge sid
                    writeBChan chan (EvToast (case r of
                      Right () -> "Session deleted: " <> T.pack sid
                      Left e   -> "Error: " <> T.pack (show e)))
                (Nothing, Nothing, Just (_, act)) -> do
                  -- 通用确认槽（/forget、/clear-attachments、/update pull …）：
                  -- action 自带回执（toast / 事件），这里只负责弹栈与执行。
                  modify $ \s -> s { appDialogs = stackPop (appDialogs s)
                                   , appPendingConfirm = Nothing }
                  void $ liftIO $ async act
                (Nothing, Nothing, Nothing) -> do  -- persist the rule, then approve once
                  modify $ \s -> s { appDialogs = stackPop (appDialogs s) }
                  let (name, args) = fromMaybe ("", []) (appAskTool st2)
                      bridge = appBridge st2
                      chan   = appChan st2
                  case appSessionId st2 of
                    Nothing -> decideApprovalNow True
                    Just sid -> do
                      modify $ \s2 -> s2 { appStatus = tr (appLang s2) "Approving..." }
                      void $ liftIO $ async $ do
                        _ <- allowAlways bridge name args  -- best effort: a failed rule
                                                           -- still allows this once
                        r <- decidePlan bridge sid True
                        writeBChan chan (EvVerdict r)
          _ -> do  -- no: cancel the pending stop / generic confirm, or go back to the approval card
            st2 <- get
            if appPendingStop st2
              then modify $ \s -> s { appPendingStop = False }
              else if isJust (appPendingConfirm st2)
                then modify $ \s -> s { appPendingConfirm = Nothing
                                       , appDialogs = stackPop (appDialogs s) }
                else do
                  modify $ \s -> s { appPendingDelete = Nothing, appPendingProviderRemove = Nothing }
                  st3 <- get
                  case (appApproval st3, appAskTool st3) of
                    (Just msg, Just (name, args)) ->
                      modifyTop (const (DialogApproval msg name args 0))
                    _ -> modify $ \s2 -> s2 { appDialogs = stackPop (appDialogs s2) }

-- | Keys in the normal chat view.

handleDialogKey :: Event -> EventM ResourceName AppState ()
handleDialogKey (EvKey KUp [])    = modifyTop (dialogMoveSel (-1))
handleDialogKey (EvKey KDown [])  = modifyTop (dialogMoveSel 1)
handleDialogKey (EvKey (KChar 'p') [MCtrl]) = modifyTop (dialogMoveSel (-1))
handleDialogKey (EvKey (KChar 'n') [MCtrl]) = modifyTop (dialogMoveSel 1)
-- | tab：列表前进（vty 把 Tab 报成 KChar '\t'）。
handleDialogKey (EvKey (KChar '\t') []) = modifyTop (dialogMoveSel 1)
handleDialogKey (EvKey KEnter []) = dialogActivate
handleDialogKey (EvKey KBS [])    = withCommands dialogDelete >> scrollBottom
-- | j/k：没有查询行的列表用 vim 风格上下移动（Reasonix 的 prompts.go）。
-- 有查询行的列表（命令/技能/模型/会话）里 j/k 是普通字符，不抢导航。
handleDialogKey (EvKey (KChar c) [])
  | c == 'j' || c == 'k' = do
      st <- get
      case stackTop (appDialogs st) of
        Just DialogCommands{} -> withCommands (dialogAppend c) >> scrollBottom
        Just DialogSkills{}   -> withCommands (dialogAppend c) >> scrollBottom
        Just DialogModels{}   -> withCommands (dialogAppend c) >> scrollBottom
        Just DialogSessions{} -> withCommands (dialogAppend c) >> scrollBottom
        _ -> modifyTop (dialogMoveSel (if c == 'j' then 1 else -1))
handleDialogKey (EvKey (KChar c) [])
  | let o = fromEnum c in o >= 32 && o < 127 = do
      st <- get
      case stackTop (appDialogs st) of
        Just (DialogProviders ps sel) | c == 'a' ->
          modify $ \s -> s { appDialogs = stackPush (DialogPresets presets 0) (appDialogs s) }
        Just (DialogProviders ps sel) | c == 'e'
          , (p : _) <- drop sel ps -> startWizard (Just p)
        Just (DialogProviders ps sel) | c == 'r'
          , (p : _) <- drop sel ps -> refreshProviderEfforts p
        Just (DialogProviders ps sel) | c == 'd'
          , (p : _) <- drop sel ps -> startProviderRemove p
        Just (DialogProviders ps sel) | c == 't'
          , (p : _) <- drop sel ps -> toggleProviderThinking p
        _ -> withCommands (dialogAppend c) >> scrollBottom
handleDialogKey _ = return ()

-- | Editing keys apply only to the command dialog (approval/confirm have
-- no query row).
-- | dialogAppend / dialogDelete / withCommands / modifyTop 见 UI.Brick.DialogKeys。

-- | Activate the entry under the top dialog's cursor.
-- | Adopt a provider: remember it and make sure the current model belongs
-- to it (otherwise fall back to the provider's default).  The dialog has
-- already been popped by 'dialogActivate'.

-- 持久化。DialogProviders 的 't' 与 settings 的 Providers 页签共用。
toggleProviderThinking :: ProviderInfo -> EventM ResourceName AppState ()
toggleProviderThinking p = do
  st <- get
  let bridge = appBridge st
      chan   = appChan st
      next   = if piThinking p == "yes" then "no" else "yes"
  modify $ \s -> s { appStatus = tr (appLang st) "Saving thinking toggle..." }
  void $ liftIO $ async $ do
    r <- saveProvider bridge (piName p) (piKind p) (piBaseUrl p) ""
           (piModels p) (piDefault p) (piAuthHeader p) (piNoProxy p)
           (piEffort p) (piVision p) (piEfforts p)
           (piHeaders p) (piExtraBody p) next (piResponsesMode p)
           (piContextWindow p)
    writeBChan chan (case r of
      Right _  -> EvToast (T.pack "thinking: " <> next)
      Left e   -> EvToast (T.pack ("Error: " <> show e)))

-- | 删除确认入口（tui-port L290）：pending 标记 + DialogConfirm（默认取消）。
-- 确认后的实际删除在 DialogConfirm 分发（appPendingProviderRemove）。
startProviderRemove :: ProviderInfo -> EventM ResourceName AppState ()
startProviderRemove p = do
  st <- get
  modify $ \s -> s
    { appPendingProviderRemove = Just (piName p)
    , appDialogs = stackPush
        (DialogConfirm (T.pack ("Remove provider " <> T.unpack (piName p) <> "?")) 1)
        (appDialogs st) }

refreshProviderEfforts :: ProviderInfo -> EventM ResourceName AppState ()
refreshProviderEfforts p = do
  st <- get
  let bridge = appBridge st
      chan = appChan st
  modify $ \s -> s { appStatus = "Probing " <> piName p <> "..." }
  void $ liftIO $ async $ do
    r <- probeProvider bridge (piBaseUrl p) ""
    case r of
      Right probe -> do
        saved <- saveProvider bridge (piName p) (piKind p) (piBaseUrl p) ""
                   (piModels p) (piDefault p) (piAuthHeader p) (piNoProxy p)
                   (piEffort p) (piVision p) (ppEfforts probe)
                   (piHeaders p) (piExtraBody p) (piThinking p) (piResponsesMode p)
                   (piContextWindow p)
        writeBChan chan (EvProviderSaved saved)
      Left e -> writeBChan chan (EvProviderSaved (Left e))

