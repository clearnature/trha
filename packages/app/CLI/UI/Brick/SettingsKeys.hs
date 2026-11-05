{-# LANGUAGE OverloadedStrings #-}

-- | 设置面板的按键处理：列表导航、编辑态、选项循环、关闭。
--
-- 从 "UI.Brick.KeyDispatch" 拆出。全局键位（leader / Ctrl+C / Ctrl+D）留在
-- KeyDispatch，它只在这里调一次 handleSettingsKey。
module UI.Brick.SettingsKeys
  ( handleSettingsKey, closeSettingsPanel, applySetting, moveTab, editingNow
  , moveTabBy, moveListSel, seedEdit, clampSel, nextOption, settingsListWidth
  ) where

import Brick
import Brick.BChan
import Brick.Widgets.Border
import Brick.Widgets.Edit
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
import UI.Commands (runSettingsCommand)
import UI.Commands.Registry
    ( Command(..), parseCommandWith, pickerItems, pickerItemsGrouped
    , groupKey, groupTitle, helpTextFor, registryHelp )
import UI.SettingsView (SettingsEntry(..), settingsEntries, filterEntries, isOverridden, maskSecret)
import UI.State
import UI.StatusInfo (StatusRow(..), collectStatusInfo)
import UI.StatsView (StatsBlock(..), buildStatsBlocks)
import UI.I18n (Lang(..), langName, parseLang, tr)
import Config.Settings (resolveConfig)
import qualified Data.Map.Strict as Map
import UI.Brick.Settings.Pure
  ( clampSel, editingNow, moveTab, nextOption, seedEdit, settingsListWidth )
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
import UI.Brick.Selection
  ( beginSel, extendSel, copySelectionText, finishSel, copyToClipboard
  , moveCardFocus, toggleFocusedCard, toolCardIds )
import UI.Brick.Input
  ( alwaysConfirmText, editorCursor, editorValue, promptIsEmpty )
import UI.Brick.SessionView
  ( blocksToMessages, localSessionLines, refreshSidebar, resumeSession )
import UI.Render.Picker (queryAppend, queryDelete)
import UI.Render.ToolCard (ToolFold(..), toggleFold)
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
import UI.Brick.Draw.Messages
  ( cardHidden, diffWidget, drawHome, drawInput, drawMessage, drawMessages
  , drawPending, drawPlanCard, drawToast, drawUI, messageBody, messageHeader
  , renderBlocks, renderToolBody, roleStyle )
import UI.Brick.Draw.Settings (visibleRows)
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

handleSettingsKey :: Event -> EventM ResourceName AppState ()
handleSettingsKey (EvKey KEsc []) = do
  st <- get
  case appSettings st of
    -- editing: cancel the edit first
    Just p | Just _ <- spEdit p ->
      modify $ \s -> s { appSettings = Just p { spEdit = Nothing } }
    -- search/list zone with a query: clear it before closing
    Just p | (spFocus p == FocusSearch || spFocus p == FocusList) && not (T.null (spQuery p)) ->
      modify $ \s -> s { appSettings = Just p { spQuery = "", spSel = 0 } }
    _ -> closeSettingsPanel
-- left/right switch the tab from any zone (ignored while editing)
handleSettingsKey (EvKey KLeft []) = do
  st <- get
  if editingNow st then return () else moveTabBy (-1)
handleSettingsKey (EvKey KRight []) = do
  st <- get
  if editingNow st then return () else moveTabBy 1
-- up: search -> tabs ; list top (no query) -> search
handleSettingsKey (EvKey KUp []) = do
  st <- get
  case appSettings st of
    Just p | spFocus p == FocusSearch ->
      modify $ \s -> s { appSettings = Just p { spFocus = FocusTabs } }
    Just p | spFocus p == FocusList && spSel p == 0 && T.null (spQuery p) ->
      modify $ \s -> s { appSettings = Just p { spFocus = FocusSearch } }
    Just p | spFocus p == FocusList -> moveListSel (-1)
    _ -> return ()
-- down: tabs -> search (settings tab) ; search -> list ; list wraps
handleSettingsKey (EvKey KDown []) = do
  st <- get
  case appSettings st of
    Just p | spFocus p == FocusTabs && spTab p == TabSettings ->
      modify $ \s -> s { appSettings = Just p { spFocus = FocusSearch } }
    Just p | spFocus p == FocusSearch ->
      modify $ \s -> s { appSettings = Just p { spFocus = FocusList } }
    Just p | spFocus p == FocusList -> moveListSel 1
    _ -> return ()
handleSettingsKey (EvKey KEnter []) = do
  st <- get
  case appSettings st of
    Nothing -> return ()
    Just p | Just buf <- spEdit p -> do
      let rows = visibleRows st
      case drop (spSel p) rows of
        e : _ -> applySetting (seKey e) buf
        []    -> return ()
    Just p -> case (spTab p, spFocus p) of
      (TabStatus, _)  -> return ()  -- read-only content
      (TabStats, _)   -> return ()
      (TabProviders, FocusList) -> case drop (spSel p) (appProviders st) of
        (p2 : _) -> chooseProvider p2
        []       -> return ()
      (TabSettings, FocusTabs) ->
        modify $ \s -> s { appSettings = Just p { spFocus = FocusSearch } }
      (TabSettings, FocusSearch) ->
        modify $ \s -> s { appSettings = Just p { spFocus = FocusList } }
      (TabSettings, FocusList) -> do
        let rows = visibleRows st
        case drop (spSel p) rows of
          e : _ | seKind e == "bool" -> applySetting (seKey e) (if seVal e == "true" then "false" else "true")
          e : _ | not (null (seOptions e)) ->
            applySetting (seKey e) (nextOption (seOptions e) (seVal e))
          e : _ -> modify $ \s -> s { appSettings = Just p { spEdit = Just (seedEdit e) } }
          []    -> return ()
handleSettingsKey (EvKey (KChar c) []) = do
  st <- get
  let o = fromEnum c
  case appSettings st of
    Just p | Just buf <- spEdit p ->
      modify $ \s -> s { appSettings = Just p { spEdit = Just (buf <> T.singleton c) } }
    Just p | spTab p == TabSettings && spFocus p == FocusSearch, o >= 32 && o < 127 ->
      modify $ \s -> s { appSettings = Just p { spQuery = queryAppend (spQuery p) c, spSel = 0 } }
    Just p | spTab p == TabSettings && spFocus p == FocusList, o >= 32 && o < 127 ->
      modify $ \s -> s { appSettings = Just p { spQuery = queryAppend (spQuery p) c, spSel = 0 } }
    Just p | spTab p == TabProviders && spFocus p == FocusList, o >= 32 && o < 127 ->
      -- Providers 页签的动作键（tui-port L290）：t=思考开关、d=删除确认
      --（复用 DialogProviders 的同款逻辑）。
      case (c, drop (spSel p) (appProviders st)) of
        ('t', (p2 : _)) -> toggleProviderThinking p2
        ('d', (p2 : _)) -> startProviderRemove p2
        _               -> return ()
    _ -> return ()
handleSettingsKey (EvKey KBS []) = do
  st <- get
  case appSettings st of
    Just p | Just buf <- spEdit p ->
      modify $ \s -> s { appSettings = Just p { spEdit = Just (T.dropEnd 1 buf) } }
    Just p | spFocus p == FocusSearch || spFocus p == FocusList ->
      modify $ \s -> s { appSettings = Just p { spQuery = queryDelete (spQuery p), spSel = 0 } }
    _ -> return ()
handleSettingsKey _ = return ()

-- | Is a value edit in progress?

closeSettingsPanel :: EventM ResourceName AppState ()
closeSettingsPanel = modify $ \s -> s { appSettings = Nothing }

-- | Apply one edited value and refresh the snapshot.

applySetting :: Text -> Text -> EventM ResourceName AppState ()
applySetting key raw = do
  lang <- gets appLang
  msg <- liftIO (runSettingsCommand lang (key <> " " <> raw))
  cfg <- liftIO (resolveConfig defaultCLIConfig)
  modify $ \s -> s { appEffCfg = cfg
                    , appSettings = (\p -> p { spEdit = Nothing, spError = Nothing }) <$> appSettings s }
  case msg of
    Just m | any (`T.isPrefixOf` m) ["Error: ", "Unknown", "Value must", "错误：", "未知", "值必须"] ->
      modify $ \s -> s { appSettings = (\p -> p { spError = Just m }) <$> appSettings s }
    Just m ->
      modify $ \s -> s { appSettings = (\p -> p { spError = Just (tr (appLang s) "Saved: " <> m) }) <$> appSettings s }
    Nothing -> return ()

-- | Move the tab by a delta (wraps around the tab list).



moveTabBy :: Int -> EventM ResourceName AppState ()
moveTabBy d = modify $ \s -> s { appSettings = (\p -> p { spTab = moveTab d (spTab p)
                                                           , spSel = 0, spQuery = "", spEdit = Nothing, spError = Nothing }) <$> appSettings s }

-- | Move the list selection by a delta, wrapping around (qwen behaviour:
-- down at the end returns to the top).

moveListSel :: Int -> EventM ResourceName AppState ()
moveListSel d = do
  st <- get
  let n = case appSettings st of
        Just p | spTab p == TabProviders -> length (appProviders st)
        _                                -> length (visibleRows st)
  modify $ \s -> s { appSettings = (\p -> p { spSel = if n <= 0 then 0 else mod (spSel p + d + n) n }) <$> appSettings s }
-- | Initial edit buffer: current value, except secrets which start empty.




