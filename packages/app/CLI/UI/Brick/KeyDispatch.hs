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
import Data.Time.Clock (getCurrentTime)
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
import UI.Brick.AppEvent (handleAppEvent)
import UI.Render.Picker (filterItems, queryAppend, queryDelete)
import UI.Render.ToolCard (ToolFold(..), toggleFold)
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
import UI.ModelPrefs (ModelPrefs(..), emptyModelPrefs, toggleFavorite, recordRecent, orderedModels, loadModelPrefs, saveModelPrefs)
import Data.Time.Clock (UTCTime, diffUTCTime)

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
moveTab :: Int -> SettingsTab -> SettingsTab
moveTab d t = toEnum (mod (fromEnum t + d) (fromEnum (maxBound :: SettingsTab) + 1))
-- | Keys while the settings panel is open (three-zone focus model, mirroring
-- the reference dialog: tabs -> search -> list -> editing).
-- | handleSettingsKey 见 UI.Brick.KeyDispatch。

editingNow :: AppState -> Bool
editingNow st = case appSettings st of
  Just p | Just _ <- spEdit p -> True
  _ -> False

-- | Tab-bar switching shared by left/right keys.
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
seedEdit :: SettingsEntry -> Text
seedEdit e
  | seKey e == "token" = ""
  | otherwise = seVal e

-- | Widget for the settings panel (tab bar + content).
-- | drawSettingsPanel 见 UI.Brick.Draw.Settings（随 settingsRows/visibleRows 一起迁出）。

-- | Clamp a selection into @[0, n-1]@.
clampSel :: Int -> Int -> Int
clampSel n sel
  | n <= 0 = 0
  | otherwise = max 0 (min sel (n - 1))

-- | Two-column rendering of the Status rows (label column padded).
-- | renderStatusRows / computeStatsBlocks / renderStatsBlocks 见 UI.Render.Settings。


-- | Next element in a cycle (wraps to the head); falls back to the head
-- when the current value is not one of the options.
nextOption :: [Text] -> Text -> Text
nextOption opts cur = case break (== cur) opts of
  (_, [])     -> case opts of
    (x : _) -> x
    []      -> ""
  (_, x : rest) -> case rest of
    (nxt : _) -> nxt
    []        -> case opts of
      (h : _) -> h
      []      -> x

-- | Maximum panel row width (kept below the 80-column window).
settingsListWidth :: Int
settingsListWidth = 96

-- | Current git branch name, or a short SHA when detached, or "—".  Asking
-- git itself resolves worktrees, packed refs and detached HEAD correctly;
-- reading @.git/refs/heads/<branch>@ returns the commit SHA, not the name.
