{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | 命令面板（Quick Picker）：候选构造、过滤、移动与执行。
--
-- 从 @UI.Brick@ 拆出。它把 slashRegistry / 技能 / 命令三者的候选统一成
-- PickerItem，并负责面板的打开、移动、执行。
module UI.Brick.Palette
  ( refreshCompletion
  , paletteItemsFor
  , allPickerItems
  , refreshPalette
  , movePalette
  , runPaletteItem
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
  ( beginSel, extendSel, copySelectionText, finishSel, copyToClipboard )
import UI.Brick.Input
  ( alwaysConfirmText, editorCursor, editorValue, promptIsEmpty )
import UI.Brick.SessionView
  ( blocksToMessages, localSessionLines, refreshSidebar, resumeSession )
import UI.Brick.Chat (handleChatWith)
import UI.Brick.DialogActivate
  ( dialogActivate, handleDialogKey, refreshProviderEfforts
  , startProviderRemove, toggleProviderThinking )
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
import UI.InputHistory (HistState(..), emptyHistState, histUp, histDown, histCommit, loadHistory, appendHistory)
import UI.Render.Picker (PickerItem(..), filterItems, maxVisible, moveSelection, queryAppend, queryDelete, windowRange, buildPalette, isSection, firstSelectable)
import UI.ProviderPresets (Preset(..), presets, prePopular)
import Core.EffortContract (levelsFor)
import UI.Render.ToolCard (ToolStatus(..), ToolCard(..), ToolFold(..), toggleFold, toolCardWithStatus, toolStatusLine, cardWidth)
import UI.Render.ToolSummary (toolHeadline, toolDetailLines, presentCard, shouldHideTool)
import UI.Render.FilePart (filePartsOf, stripFileTokens, filePartLine)
import UI.Render.Message (classifyError, errorLabel, errorHint, metaLine)

refreshCompletion :: EventM ResourceName AppState ()
refreshCompletion = do
  st <- get
  let popup = completionPopup 8 (appIndex st) (editorValue st) (editorCursor st)
  modify $ \s -> s { appComp = popup }

-- | Palette sources: registered slash commands (grouped by function) plus
-- discovered skills and user commands.
paletteItemsFor :: AppState -> [PickerItem]
paletteItemsFor st =
  -- Recent = the 3 most recently used commands (was 3 commands + 3 skills = 6).
  buildPalette [] (take 3 (ranked cmds)) grouped skills
  where
    lang = appLang st
    skills =
      [ PickerItem ("/skill:" <> skName sk) (skName sk)
          ("skill · " <> skDescription sk)
      | sk <- appSkills st ]
    grouped =
      [ (groupKey g, groupTitle lang g, items)
      | (g, items) <- pickerItemsGrouped lang ]
      ++ [ ("custom", tr lang "custom", customItems) | not (null customItems) ]
    customItems =
      [ PickerItem ("/" <> ccName cc) ("/" <> ccName cc)
          (if T.null (T.strip (ccDescription cc))
             then tr lang "user command"
             else ccDescription cc)
      | cc <- appCustomCmds st ]
    cmds = allPickerItems st
    ranked = rankItems (appFrecency st)

-- | Built-in commands plus user commands (@~/.trha/commands@), flat (used for
-- submit-time matching, which must not see section headers).
allPickerItems :: AppState -> [PickerItem]
allPickerItems st =
  pickerItems (appLang st)
    ++ [ PickerItem ("/" <> ccName cc) ("/" <> ccName cc)
           (if T.null (T.strip (ccDescription cc))
              then tr (appLang st) "user command"
              else ccDescription cc)
       | cc <- appCustomCmds st ]

-- | Recompute the inline slash-command palette from the editor text.  A
-- single-line input starting with @/@ owns the palette; anything else
-- closes it (the list is a hint, not a mode).  A space ends the slash token:
-- once the trigger is chosen (or arguments are being typed) the list is
-- gone, exactly like MiMo's autocomplete.
refreshPalette :: EventM ResourceName AppState ()
refreshPalette = do
  st <- get
  let text = editorValue st
      single = not (T.any (== '\n') text)
      tokenOpen = not (T.any (== ' ') text)
      query = T.drop 1 text
  modify $ \s ->
    if "/" `T.isPrefixOf` text && single && tokenOpen
      then s { appPalette =
             let items = paletteItemsFor s
                 -- 选中索引必须相对于*过滤后*的列表：'dialogCommandsItems'
                 -- 每次都用 query 重新过滤，若这里按全量列表算，过滤到只剩
                 -- 一项时索引会越界，回车便落到 'runPaletteItem' 的空分支上，
                 -- 表现为「输入 /about 回车毫无反应」。
             in Just (DialogCommands items query
                        (dialogCommandsInitialSel items query)) }
      else s { appPalette = Nothing }

-- | Move the palette selection (clamped by the shared dialog state machine).
movePalette :: Int -> EventM ResourceName AppState ()
movePalette delta =
  modify $ \s -> s { appPalette = dialogMoveSel delta <$> appPalette s }

-- | Run the highlighted palette entry and close the palette.
runPaletteItem :: EventM ResourceName AppState ()
runPaletteItem = do
  st <- get
  case appPalette st of
    Nothing -> return ()
    Just d ->
      let its = dialogCommandsItems d
          -- 索引按过滤后的列表钳位：越界时退回最后一项，而不是静默关闭。
          sel = max 0 (min (dialogCommandsSelected d) (length its - 1))
      in case drop sel its of
        (item : _) | isSection item -> modify $ \s -> s { appPalette = Nothing }
        (item : _) ->
          if "/skill:" `T.isPrefixOf` piId item
            then selectSkill (T.drop 7 (piId item))
            else do
              modify $ \s -> s { appInput = editorText InputArea (Just 1) ""
                               , appPalette = Nothing }
              handleSlash (piId item)
        [] -> modify $ \s -> s { appPalette = Nothing }

-- | Persist the active provider/model so the next launch starts there.
-- | persistSelection 见 UI.Brick.DialogKeys。

-- | startWizardPreset 见 UI.Brick.Wizard。

-- | Re-probe a saved provider and write its effort ladder back (a relay may
-- have gained or lost a model's depth levels since it was saved).
-- | 供应商面板三个动作见 UI.Brick.DialogActivate。

-- | startWizard 见 UI.Brick.Wizard。

-- | Put the current field's value in the editor so the user can edit it.
-- | refreshWizardInput 见 UI.Brick.Wizard。

-- | Take the editor's text as the current field and advance (or save).
-- | commitWizard 见 UI.Brick.Wizard。

-- | A non-blank field that does not decode as JSON.
-- | invalidJson 见 UI.Brick.Wizard。

-- | Validate and POST the draft; the kernel answers with the new store.
-- | finishWizard 见 UI.Brick.Wizard。

-- | Select a skill in the palette: write the trigger into the editor and
-- stop there.  MiMo's @DialogSkill@ does exactly this (@setText("/"+name+" ")@,
-- cursor to the end); running the skill is the submit key's job, never the
-- list's.
-- | selectSkill 见 UI.Brick.DialogKeys。

-- | Run a skill.  The transcript shows the visible trigger (@/skill:<name>
-- <request>@) while the model receives the skill's instructions plus the
-- user's own request — the same split MiMo uses (visible message + body
-- injected as context).
