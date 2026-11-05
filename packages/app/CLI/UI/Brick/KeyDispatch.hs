{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | 全局键位：leader（Ctrl+X）、Ctrl+C、Ctrl+D 的处理。
--
-- 从 @UI.Brick@ 拆出。它们是 handleEvent 的分支目标，与具体视图无关。
module UI.Brick.KeyDispatch
  ( handleLeaderKey
  , disarmLeader
  , handleCtrlCKey
  , handleCtrlDKey
  , handleEvent
  , handleSettingsKey
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
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Data.Time.Clock (getCurrentTime)
import Graphics.Vty.Attributes
import Graphics.Vty.Input.Events
import qualified Graphics.Vty as V
import Lens.Micro ((&), (.~), (%~), (^.))
import UI.Brick.SettingsKeys
  ( applySetting, clampSel, closeSettingsPanel, editingNow, handleSettingsKey
  , moveListSel, moveTab, moveTabBy, nextOption, seedEdit, settingsListWidth )
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
import UI.Brick.AppEvent (handleAppEvent)
import UI.Render.ToolCard (ToolFold(..), toggleFold)
import UI.Brick.ChatKeys (editDefaultKey, handleChatKey)
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
import UI.Brick.MessageOps (now)
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
import UI.PasteFold (isLongPaste)
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

handleLeaderKey :: Event -> EventM ResourceName AppState ()
handleLeaderKey (EvKey KEsc _) = disarmLeader "Ready"
handleLeaderKey (EvKey (KChar c) []) = do
  modify $ \s -> s { appLeader = False }
  case leaderResolve c of
    Just LeaderSidebar   -> modify $ \s -> s { appSidebar = toggleSidebar (appSidebar s) }
    Just LeaderProvider  -> handleSlash "/provider"
    Just LeaderModels    -> handleSlash "/models"
    Just LeaderSessions  -> handleSlash "/sessions"
    Just LeaderSettings  -> handleSlash "/settings"
    Just LeaderHelp      -> handleSlash "/help"
    Just LeaderInterrupt -> requestInterrupt
    Nothing              -> disarmLeader "Unknown leader key"
handleLeaderKey _ = disarmLeader "Ready"

disarmLeader :: Text -> EventM ResourceName AppState ()
disarmLeader msg = modify $ \s -> s
  { appLeader = False, appStatus = tr (appLang s) msg }

-- | Ctrl+C follows the terminal convention: interrupt first, clear input
-- second, quit only on a second press from an idle empty prompt.  Ctrl+D quits
-- only from an idle empty prompt; Ctrl+Q stays as a direct exit.
handleCtrlCKey :: EventM ResourceName AppState ()
handleCtrlCKey = do
  st <- get
  now <- liftIO getCurrentTime
  -- 有选区时 ctrl+c 先复制（Reasonix 的 copyIt），否则才走中断/清空/退出。
  case appSelStart st of
    Just _  -> copySelectionText True
    Nothing -> case decideCtrlC (appBusy st) (not (promptIsEmpty st)) (appQuitLast st) now of
      CtrlCInterrupt  -> requestInterrupt
      CtrlCClearInput -> modify $ \s -> s { appInput = editorText InputArea (Just 1) "" }
      CtrlCQuit       -> halt
      CtrlCArmQuit    -> modify $ \s -> s
        { appQuitLast = Just now
        , appStatus = tr (appLang s) "Press Ctrl+C again to quit"
        }

handleCtrlDKey :: EventM ResourceName AppState ()
handleCtrlDKey = do
  st <- get
  when (decideCtrlD (appBusy st) (not (promptIsEmpty st))) halt

-- | promptIsEmpty 见 UI.Brick.Input。

-- | Ask the host to stop the running turn (shared by the leader and the
-- double-escape path).
-- | 中断/审批组见 UI.Brick.RunControl。

-- | Keys while a dialog is open: the top dialog owns them all.
-- | handleDialogKey 见 UI.Brick.DialogActivate。

-- | chooseProvider 见 UI.Brick.DialogKeys。

-- | dialogActivate 见 UI.Brick.DialogActivate。

-- | Keys in the normal chat view.
-- | handleChatKey / handleChatEnter 见 UI.Brick.ChatKeys。

-- | Run a skill.  The transcript shows the visible trigger (@/skill:<name>
-- <request>@) while the model receives the skill's instructions plus the
-- user's own request — the same split MiMo uses (visible message + body
-- injected as context).
-- | 提交路径（submitSkill/commitEditor/editExternally）见 UI.Brick.ChatKeys。


handleEvent :: BrickEvent ResourceName AppEvent -> EventM ResourceName AppState ()
handleEvent (AppEvent ev) = handleAppEvent ev
-- Shift+Tab is a global posture shortcut: handle it before dialogs/settings/
-- editors so the key can never be swallowed by another handler.
handleEvent (VtyEvent (EvKey KBackTab _)) =
  modeAction (object ["action" .= ("cycle" :: Text)])
handleEvent (VtyEvent (EvKey (KChar '\t') ms))
  | MShift `elem` ms = modeAction (object ["action" .= ("cycle" :: Text)])
handleEvent (VtyEvent (EvKey (KChar 'q') [MCtrl])) = halt
-- Ctrl+Alt+Q is the *service-level* stop (kernel + scheduler), not another
-- shell exit: the kernel is shared by TUI, Desktop and Web and has no "quit"
-- of its own, so stopping it tears down every trha process.  This mirrors
-- Desktop's `Services → Stop kernel and scheduler…` and `/stop confirm`, and
-- opens the confirmation dialog first.  vty delivers Alt as an ESC prefix, so
-- the key arrives as MMeta+MCtrl (MAlt is accepted for parsers that report Alt
-- directly); GNOME Terminal binds Ctrl+Shift+Q to close-window and never
-- forwards it, so this combination is the one that reaches the shell.
handleEvent (VtyEvent (EvKey (KChar 'q') ms))
  | MCtrl `elem` ms && (MMeta `elem` ms || MAlt `elem` ms) = requestStopServices
handleEvent (VtyEvent (EvKey (KChar 'c') [MCtrl])) = handleCtrlCKey
handleEvent (VtyEvent (EvKey (KChar 'd') [MCtrl])) = handleCtrlDKey
handleEvent (VtyEvent (EvKey KEsc _)) = do
  st <- get
  case appSettings st of
    Just _  -> handleSettingsKey (EvKey KEsc [])
    Nothing | isJust (appWizard st) ->
      modify $ \s -> s { appWizard = Nothing
                       , appInput = editorText InputArea (Just 1) ""
                       , appStatus = tr (appLang s) "Ready" }
    Nothing -> case appComp st of
      -- MiMo's hierarchy: the autocomplete popup closes before anything
      -- else, and closing it must not arm the interrupt double-press.
      Just _  -> modify $ \s -> s { appComp = Nothing, appEscLast = Nothing }
      Nothing -> case appPalette st of
        -- Esc dismisses the command palette without touching the input.
        Just _  -> modify $ \s -> s { appPalette = Nothing, appEscLast = Nothing }
        Nothing -> escapeHierarchy
-- Mouse drag selects whole messages (brick exposes no per-cell text map);
-- releasing copies them, so terminal row-copy is not needed.
handleEvent (MouseDown (ThinkToggle i) BLeft _ _) =
  modify $ \s -> s
    { appFolds = Map.alter (Just . toggleFold . fromMaybe FoldCollapsed) i (appFolds s) }
handleEvent (MouseDown _ BScrollUp _ _) =
  vScrollBy (viewportScroll MessageArea) (-3)
handleEvent (MouseDown _ BScrollDown _ _) =
  vScrollBy (viewportScroll MessageArea) 3
-- Drag-select still works through brick's wrapped events: anchor on the first
-- left press, extend on the following ones, copy on release.
handleEvent (MouseDown _ BLeft _ (Location (_, y))) = do
  st <- get
  if isJust (appSelStart st) then extendSel y else beginSel y
handleEvent (MouseUp _ (Just BLeft) (Location (_, y))) = finishSel y
handleEvent (VtyEvent (EvMouseDown _ y BLeft [])) = do
  st <- get
  -- vty reports a drag as repeated mouse-down events; the first one anchors.
  if isJust (appSelStart st) then extendSel y else beginSel y
handleEvent (VtyEvent (EvMouseUp _ y (Just BLeft))) = finishSel y
handleEvent (VtyEvent (EvMouseDown _ _ BScrollUp _)) =
  vScrollBy (viewportScroll MessageArea) (-3)
handleEvent (VtyEvent (EvMouseDown _ _ BScrollDown _)) =
  vScrollBy (viewportScroll MessageArea) 3
-- | 长粘贴折叠：原文存进 appPastes，输入框只放一个占位符
-- （Reasonix 的 @[Pasted text #N · X lines]@）。短粘贴照常进编辑器。
handleEvent (VtyEvent (EvPaste bs)) = do
  let txt = TE.decodeUtf8With TEE.lenientDecode bs
  if isLongPaste txt
    then insertPaste txt
    else do
      editDefaultKey (EvPaste bs)
      refreshCompletion >> refreshPalette

-- A dialog is modal: while one is open the top dialog owns every key and
-- the editor gets nothing until it closes.
handleEvent (VtyEvent ev) = do
  t <- liftIO getCurrentTime
  modify $ \s -> s { appNow = Just t }
  st <- get
  case appSettings st of
    Just _  -> handleSettingsKey ev
    Nothing -> case stackTop (appDialogs st) of
      Just _  -> handleDialogKey ev
      Nothing
        | appLeader st -> handleLeaderKey ev
        | otherwise    -> handleChatKey ev
handleEvent _ = return ()

-- | One keystroke after the leader (ctrl+x).  Executes one action, then
-- disarms; anything unbound cancels.
-- | 全局键位组见 UI.Brick.KeyDispatch。

-- | 流式处理组见 UI.Brick.AppEvent。

-- | toolCardMsg 见 UI.Brick.AppEvent。




