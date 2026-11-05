# 模块 import 精简归档（2026-11-05）

## 这是什么

拆分 `UI/Brick.hs`（4414 行）时，我给每个新模块**照抄了源文件那一整段 144 行 import**。
本记录归档随后的清理：删掉的**全部是 import 声明**（含多行 import 的续行），
**没有删除任何一行函数、类型或逻辑**。

验证方式（可自行复核）：

```bash
git show 4185dda 58e0566 db89e3c --unified=0 | grep "^-" | grep -v "^---" \
  | grep -v "^-import " | grep -v "^-    *(" | grep -v "^-  *("
# 输出为空 ⇒ 删除项全是 import 行
```

## 性质判定

| 说法 | 是否成立 |
|---|---|
| 项目里有 4857 个死符号 | ❌ 不是。指 import 列表里当前正文未引用的名字 |
| 迁移遗留的旧代码 | ❌ 不是。没有删代码 |
| 设计预留但未接线 | ❌ 不是。预留的是函数/类型，均在 |
| **拆分时照抄 import 段的产物** | ✅ 是 |

import 是名字可见性声明：删除它不影响任何已实现功能；将来接线需要时加回一行即可。

## 删除清单（按文件）

合计 1748 行（含续行），涉及 53 个文件。

### `packages/app/CLI/UI/Brick/ChatEditor.hs`

```haskell
import Brick
import Brick.BChan
import Brick.Widgets.Center (centerLayer)
import Brick.Widgets.Border
import Brick.Widgets.Edit
import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar, tryPutMVar)
import Control.Concurrent.Async (async)
import Control.Monad (filterM, forM_, forever, unless, void, when)
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
import UI.SettingsView (SettingsEntry(..), settingsEntries, filterEntries, isOverridden, maskSecret)
import UI.Render.Picker (filterItems)
import UI.Render.ToolCard (ToolFold(..))
import UI.State
import UI.StatusInfo (StatusRow(..), collectStatusInfo)
import UI.StatsView (StatsBlock(..), buildStatsBlocks)
import UI.I18n (Lang(..), langName, parseLang, tr)
import Config.Settings (resolveConfig, saveConfig)
import Data.IORef (newIORef, readIORef)
import Data.List (intersperse, find)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isJust, isNothing, listToMaybe)
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
import UI.Brick.Apply
  ( applyLanguage, applyTheme, modeAction, openSettingsPanel )
import UI.Brick.Toast (showToast)
import UI.Brick.Selection
  ( beginSel, extendSel, copySelectionText, finishSel, copyToClipboard
import UI.Brick.Input
  ( alwaysConfirmText, editorCursor, editorValue, promptIsEmpty )
import UI.Brick.SessionView
  ( blocksToMessages, localSessionLines, refreshSidebar, resumeSession )
import UI.Brick.Chat (handleChatWith)
import UI.Brick.DialogActivate
  ( dialogActivate, handleDialogKey, refreshProviderEfforts
import UI.Brick.Palette
  ( allPickerItems, movePalette, paletteItemsFor, refreshCompletion
import UI.Brick.InputOps
  ( clearView, insertPaste, pasteClipboardText, pasteImage, recordVoice
import UI.Brick.Slash (handleSlash)
import UI.Brick.Wizard
  ( commitWizard, finishWizard, invalidJson, refreshWizardInput
import UI.Brick.RunControl
  ( approveAndRun, decideApprovalNow, escapeHierarchy, escapeWithoutApproval
import UI.Brick.MessageOps (appendMsg, now, setWindowTitle)
import UI.Brick.Draw.Messages
  ( cardHidden, diffWidget, drawHome, drawInput, drawMessage, drawMessages
import UI.Brick.Draw.Settings (drawSettingsPanel, settingsListMax, settingsRows, visibleRows)
import UI.Brick.Draw.Sidebar (drawCompletion, drawSidebar, sidebarDataFor)
import UI.Brick.Draw.Status
  ( drawStatus, modelLabel, pricesOf, statusLine
import UI.Render.Footer (FooterLive(..), footerMetrics, parseMetrics, branchFromHead, statusFitsOneRow, wrapStatusLine)
import UI.Render.Spans
  ( SpanTok(..), boolText, diffAttrOf, fillLines, isCompactionMark
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
import Control.Exception (IOException, SomeException, catch, try)
import Core.RunLog (logLine)
import UI.Render.Markdown (MdBlock(..), MdSpan(..), parseMarkdown)
import UI.Dialog
import UI.Render.Diff
    ( DiffClass(..), DiffLayout(..), DiffRow(..), diffClass, diffLayout, numberDiff
import UI.Layout
    ( SidebarState(..), SidebarRender(..), sidebarRender, messageWidth, toggleSidebar )
import UI.Render.Settings (computeStatsBlocks, renderStatsBlocks, renderStatusRows)
import UI.Render.Sidebar
    ( SidebarData(..), SidebarLine(..), sidebarLines, sidebarHint, agentTreeLines
import UI.Completion
    ( Completion(..), CompletionState(..), completionPopup, moveCompletion
import UI.IndexCache (scanProjectCached)
import UI.Keys (LeaderAction(..), leaderResolve, leaderHelp, CtrlCAction(..), decideCtrlC, decideCtrlD)
import UI.Skills (Skill(..), scanSkills, skillDirs, parseSkillInvocation, skillTurn)
import UI.CustomCommands (CustomCommand(..), loadCustomCommands, renderCustomCommand)
import UI.Stash (Stash(..), emptyStash, stashPush, stashPop, stashEntries, loadStash, saveStash)
import UI.Frecency (Frecency(..), emptyFrecency, recordUse, rankItems, loadFrecency, saveFrecency)
import UI.ModelPrefs (ModelPrefs(..), emptyModelPrefs, toggleFavorite, recordRecent, orderedModels, loadModelPrefs, saveModelPrefs)
import Data.Time.Clock (UTCTime, diffUTCTime)
import UI.InputHistory (HistState(..), emptyHistState, histUp, histDown, histCommit, loadHistory, appendHistory)
```

恢复：`git show 4185dda 58e0566 db89e3c -- "packages/app/CLI/UI/Brick/ChatEditor.hs" | grep "^+import"`

### `packages/app/CLI/UI/Brick/AppEvent/Stream.hs`

```haskell
import Brick.Widgets.Center (centerLayer)
import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar, tryPutMVar)
import Control.Concurrent.Async (async)
import Data.Foldable (msum)
import Control.Monad (filterM, forM_, forever, unless, void, when)
import System.Timeout (timeout)
import Core.Clipboard (readClipboardText, saveClipboardImage)
import Core.Bootstrap (ensureBackend)
import Core.RunState (stopAll, stopResultText)
import Core.Export (exportMarkdown, exportJson, defaultExportName)
import Core.PlanStore (savePlanSnapshot)
import Core.ProjectStore (ensureProject, recordProjectSession)
import Core.Transcript (listLocalSessions, listLocalSessionsIn, loadTranscript, recordChunk, recordSession, recordToolEvent, recordUser)
import UI.Commands (executeCommand, runSettingsCommand, runLocalShell, resumeSessions, resumeMessages)
import Config.Settings (resolveConfig, saveConfig)
import Data.IORef (newIORef, readIORef)
import Data.List (intersperse, find)
import Data.Maybe (fromMaybe, isJust, isNothing, listToMaybe)
import Data.Text (Text)
import Data.Time.Clock (UTCTime, diffUTCTime, getCurrentTime)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Time.LocalTime (TimeZone, getCurrentTimeZone, utcToZonedTime)
import Data.Time.Format (formatTime, defaultTimeLocale)
import Graphics.Vty.Config (defaultConfig)
import Graphics.Vty.CrossPlatform (mkVty)
import UI.Brick.Draw.Dialog (drawDialog, drawPalette, drawWizard, wizardSummary)
import UI.Selection (inSelRange)
import UI.Brick.Toast (showToast)
import UI.Brick.Chat (handleChatWith)
import UI.Brick.AppEvent.Model (handleModelEvent)
import UI.Brick.AppEvent.Plan (handlePlanEvent)
import UI.Brick.AppEvent.Session (handleSessionEvent)
import UI.Brick.AppEvent.Sidebar (handleSidebarEvent)
import UI.Brick.AppEvent.Status (handleStatusEvent)
import UI.Brick.AppEvent.Toast (handleToastEvent)
import UI.Brick.ChatKeys (editDefaultKey, handleChatEnter, handleChatKey)
import UI.Brick.Slash (handleSlash)
import UI.Brick.MessageOps (appendMsg, now, setWindowTitle)
import UI.Brick.Draw.Settings (drawSettingsPanel, settingsListMax, settingsRows, visibleRows)
import UI.Brick.Draw.Sidebar (drawCompletion, drawSidebar, sidebarDataFor)
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
import Control.Exception (IOException, SomeException, catch, try)
import Core.RunLog (logLine)
import UI.ModelPrefs (orderedModels)
import UI.Render.Message (metaLine)
import UI.Render.Settings (computeStatsBlocks, renderStatsBlocks, renderStatusRows)
import UI.IndexCache (scanProjectCached)
```

恢复：`git show 4185dda 58e0566 db89e3c -- "packages/app/CLI/UI/Brick/AppEvent/Stream.hs" | grep "^+import"`

### `packages/app/CLI/UI/Brick/AppEvent/Tools.hs`

```haskell
import Brick.Widgets.Center (centerLayer)
import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar, tryPutMVar)
import Control.Concurrent.Async (async)
import Data.Foldable (msum)
import Control.Monad (filterM, forM_, forever, unless, void, when)
import System.Timeout (timeout)
import Core.Clipboard (readClipboardText, saveClipboardImage)
import Core.Bootstrap (ensureBackend)
import Core.RunState (stopAll, stopResultText)
import Core.Export (exportMarkdown, exportJson, defaultExportName)
import Core.PlanStore (savePlanSnapshot)
import Core.ProjectStore (ensureProject, recordProjectSession)
import Core.Transcript (listLocalSessions, listLocalSessionsIn, loadTranscript, recordChunk, recordSession, recordToolEvent, recordUser)
import UI.Commands (executeCommand, runSettingsCommand, runLocalShell, resumeSessions, resumeMessages)
import Config.Settings (resolveConfig, saveConfig)
import Data.IORef (newIORef, readIORef)
import Data.List (intersperse, find)
import Data.Maybe (fromMaybe, isJust, isNothing, listToMaybe)
import Data.Time.Clock (UTCTime, diffUTCTime, getCurrentTime)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Time.LocalTime (TimeZone, getCurrentTimeZone, utcToZonedTime)
import Data.Time.Format (formatTime, defaultTimeLocale)
import Graphics.Vty.Config (defaultConfig)
import Graphics.Vty.CrossPlatform (mkVty)
import UI.Brick.Draw.Dialog (drawDialog, drawPalette, drawWizard, wizardSummary)
import UI.Selection (inSelRange)
import UI.Brick.Toast (showToast)
import UI.Brick.Chat (handleChatWith)
import UI.Brick.AppEvent.Model (handleModelEvent)
import UI.Brick.AppEvent.Plan (handlePlanEvent)
import UI.Brick.AppEvent.Session (handleSessionEvent)
import UI.Brick.AppEvent.Stream (handleStreamEvent)
import UI.Brick.AppEvent.Sidebar (handleSidebarEvent)
import UI.Brick.AppEvent.Status (handleStatusEvent)
import UI.Brick.AppEvent.Toast (handleToastEvent)
import UI.Brick.ChatKeys (editDefaultKey, handleChatEnter, handleChatKey)
import UI.Brick.Slash (handleSlash)
import UI.Brick.MessageOps (appendMsg, now, setWindowTitle)
import UI.Brick.Draw.Settings (drawSettingsPanel, settingsListMax, settingsRows, visibleRows)
import UI.Brick.Draw.Sidebar (drawCompletion, drawSidebar, sidebarDataFor)
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
import Control.Exception (IOException, SomeException, catch, try)
import Core.RunLog (logLine)
import UI.ModelPrefs (orderedModels)
import UI.Render.Message (metaLine)
import UI.Render.Settings (computeStatsBlocks, renderStatsBlocks, renderStatusRows)
import UI.IndexCache (scanProjectCached)
```

恢复：`git show 4185dda 58e0566 db89e3c -- "packages/app/CLI/UI/Brick/AppEvent/Tools.hs" | grep "^+import"`

### `packages/app/CLI/UI/Brick/Slash/Integration.hs`

```haskell
import Brick.Widgets.Center (centerLayer)
import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar, tryPutMVar)
import Control.Concurrent.Async (async)
import Control.Monad (filterM, forM_, forever, unless, void, when)
import System.Timeout (timeout)
import Core.Clipboard (readClipboardText, saveClipboardImage)
import Core.Bootstrap (ensureBackend)
import Core.RunState (stopAll, stopResultText)
import Core.Export (exportMarkdown, exportJson, defaultExportName)
import Core.PlanStore (savePlanSnapshot)
import Core.ProjectStore (ensureProject, recordProjectSession)
import Core.Transcript (listLocalSessions, listLocalSessionsIn, loadTranscript, recordChunk, recordSession, recordToolEvent, recordUser)
import UI.Commands (executeCommand, runSettingsCommand, runLocalShell, resumeSessions, resumeMessages)
import Config.Settings (resolveConfig, saveConfig)
import Data.IORef (newIORef, readIORef)
import Data.List (intersperse, find)
import Data.Foldable (msum)
import Data.Maybe (fromMaybe, isJust, isNothing, listToMaybe)
import Data.Text (Text)
import Data.Time.Clock (getCurrentTime)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Time.LocalTime (TimeZone, getCurrentTimeZone, utcToZonedTime)
import Data.Time.Format (formatTime, defaultTimeLocale)
import Graphics.Vty.Config (defaultConfig)
import Graphics.Vty.CrossPlatform (mkVty)
import UI.Brick.Draw.Dialog (drawDialog, drawPalette, drawWizard, wizardSummary)
import UI.Selection (inSelRange)
import UI.Brick.Toast (showToast)
import UI.Brick.Slash.Info (handleInfoSlash)
import UI.Brick.Slash.Lifecycle (handleLifecycleSlash)
import UI.Brick.Slash.Session (handleSessionSlash)
import UI.Brick.Slash.Config (handleConfigSlash)
import UI.Brick.Slash.Workspace (handleWorkspaceSlash)
import UI.Brick.Chat (handleChatWith)
import UI.Brick.MessageOps (appendMsg, now, setWindowTitle)
import UI.Brick.Draw.Settings (drawSettingsPanel, settingsListMax, settingsRows, visibleRows)
import UI.Brick.Draw.Sidebar (drawCompletion, drawSidebar, sidebarDataFor)
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
import Control.Exception (IOException, SomeException, catch, try)
import Core.RunLog (logLine)
import UI.Render.Settings (computeStatsBlocks, renderStatsBlocks, renderStatusRows)
import UI.IndexCache (scanProjectCached)
import Data.Time.Clock (UTCTime, diffUTCTime)
import Core.EffortContract (levelsFor)
import UI.Render.ToolSummary (toolHeadline, toolDetailLines, presentCard, shouldHideTool)
import UI.Render.FilePart (filePartsOf, stripFileTokens, filePartLine)
import UI.Render.Message (classifyError, errorLabel, errorHint, metaLine)
```

恢复：`git show 4185dda 58e0566 db89e3c -- "packages/app/CLI/UI/Brick/Slash/Integration.hs" | grep "^+import"`

### `packages/app/CLI/UI/Brick/Slash/Model.hs`

```haskell
import Brick.Widgets.Center (centerLayer)
import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar, tryPutMVar)
import Control.Monad (filterM, forM_, forever, unless, void, when)
import System.Timeout (timeout)
import Core.Clipboard (readClipboardText, saveClipboardImage)
import Core.Bootstrap (ensureBackend)
import Core.RunState (stopAll, stopResultText)
import Core.Export (exportMarkdown, exportJson, defaultExportName)
import Core.PlanStore (savePlanSnapshot)
import Core.ProjectStore (ensureProject, recordProjectSession)
import Core.Transcript (listLocalSessions, listLocalSessionsIn, loadTranscript, recordChunk, recordSession, recordToolEvent, recordUser)
import UI.Commands (executeCommand, runSettingsCommand, runLocalShell, resumeSessions, resumeMessages)
import Data.IORef (newIORef, readIORef)
import Data.List (intersperse, find)
import Data.Foldable (msum)
import Data.Maybe (fromMaybe, isJust, isNothing, listToMaybe)
import Data.Text (Text)
import Data.Time.Clock (getCurrentTime)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Time.LocalTime (TimeZone, getCurrentTimeZone, utcToZonedTime)
import Data.Time.Format (formatTime, defaultTimeLocale)
import Graphics.Vty.Config (defaultConfig)
import Graphics.Vty.CrossPlatform (mkVty)
import UI.Brick.Draw.Dialog (drawDialog, drawPalette, drawWizard, wizardSummary)
import UI.Selection (inSelRange)
import UI.Brick.Slash.Info (handleInfoSlash)
import UI.Brick.Slash.Lifecycle (handleLifecycleSlash)
import UI.Brick.Slash.Session (handleSessionSlash)
import UI.Brick.Slash.Config (handleConfigSlash)
import UI.Brick.Slash.Integration (handleIntegrationSlash)
import UI.Brick.Slash.Workspace (handleWorkspaceSlash)
import UI.Brick.Chat (handleChatWith)
import UI.Brick.MessageOps (appendMsg, now, setWindowTitle)
import UI.Brick.Draw.Settings (drawSettingsPanel, settingsListMax, settingsRows, visibleRows)
import UI.Brick.Draw.Sidebar (drawCompletion, drawSidebar, sidebarDataFor)
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
import Control.Exception (IOException, SomeException, catch, try)
import Core.RunLog (logLine)
import UI.Render.Settings (computeStatsBlocks, renderStatsBlocks, renderStatusRows)
import UI.IndexCache (scanProjectCached)
import Data.Time.Clock (UTCTime, diffUTCTime)
import UI.Render.ToolSummary (toolHeadline, toolDetailLines, presentCard, shouldHideTool)
import UI.Render.FilePart (filePartsOf, stripFileTokens, filePartLine)
import UI.Render.Message (classifyError, errorLabel, errorHint, metaLine)
```

恢复：`git show 4185dda 58e0566 db89e3c -- "packages/app/CLI/UI/Brick/Slash/Model.hs" | grep "^+import"`

### `packages/app/CLI/UI/Brick/Slash/Plan.hs`

```haskell
import Brick.Widgets.Center (centerLayer)
import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar, tryPutMVar)
import Control.Monad (filterM, forM_, forever, unless, void, when)
import System.Timeout (timeout)
import Core.Clipboard (readClipboardText, saveClipboardImage)
import Core.Bootstrap (ensureBackend)
import Core.RunState (stopAll, stopResultText)
import Core.Export (exportMarkdown, exportJson, defaultExportName)
import Core.PlanStore (savePlanSnapshot)
import Core.ProjectStore (ensureProject, recordProjectSession)
import Core.Transcript (listLocalSessions, listLocalSessionsIn, loadTranscript, recordChunk, recordSession, recordToolEvent, recordUser)
import UI.Commands (executeCommand, runSettingsCommand, runLocalShell, resumeSessions, resumeMessages)
import Config.Settings (resolveConfig, saveConfig)
import Data.IORef (newIORef, readIORef)
import Data.List (intersperse, find)
import Data.Foldable (msum)
import Data.Maybe (fromMaybe, isJust, isNothing, listToMaybe)
import Data.Text (Text)
import Data.Time.Clock (getCurrentTime)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Time.LocalTime (TimeZone, getCurrentTimeZone, utcToZonedTime)
import Data.Time.Format (formatTime, defaultTimeLocale)
import Graphics.Vty.Config (defaultConfig)
import Graphics.Vty.CrossPlatform (mkVty)
import UI.Brick.Draw.Dialog (drawDialog, drawPalette, drawWizard, wizardSummary)
import UI.Selection (inSelRange)
import UI.Brick.Toast (showToast)
import UI.Brick.Slash.Info (handleInfoSlash)
import UI.Brick.Slash.Lifecycle (handleLifecycleSlash)
import UI.Brick.Slash.Session (handleSessionSlash)
import UI.Brick.Slash.Config (handleConfigSlash)
import UI.Brick.Slash.Integration (handleIntegrationSlash)
import UI.Brick.Slash.Model (handleModelSlash)
import UI.Brick.Slash.Workspace (handleWorkspaceSlash)
import UI.Brick.Chat (handleChatWith)
import UI.Brick.MessageOps (appendMsg, now, setWindowTitle)
import UI.Brick.Draw.Settings (drawSettingsPanel, settingsListMax, settingsRows, visibleRows)
import UI.Brick.Draw.Sidebar (drawCompletion, drawSidebar, sidebarDataFor)
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
import Control.Exception (IOException, SomeException, catch, try)
import Core.RunLog (logLine)
import UI.Render.Settings (computeStatsBlocks, renderStatsBlocks, renderStatusRows)
import UI.IndexCache (scanProjectCached)
import Data.Time.Clock (UTCTime, diffUTCTime)
import Core.EffortContract (levelsFor)
import UI.Render.ToolSummary (toolHeadline, toolDetailLines, presentCard, shouldHideTool)
import UI.Render.FilePart (filePartsOf, stripFileTokens, filePartLine)
import UI.Render.Message (classifyError, errorLabel, errorHint, metaLine)
```

恢复：`git show 4185dda 58e0566 db89e3c -- "packages/app/CLI/UI/Brick/Slash/Plan.hs" | grep "^+import"`

### `packages/app/CLI/UI/Brick.hs`

```haskell
import Brick.Widgets.Center (centerLayer)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar, tryPutMVar)
import Control.Monad (filterM, forM_, forever, unless, void, when)
import System.Timeout (timeout)
import Core.Clipboard (readClipboardText, saveClipboardImage)
import Core.Bootstrap (ensureBackend)
import Core.RunState (stopAll, stopResultText)
import Core.Export (exportMarkdown, exportJson, defaultExportName)
import Core.PlanStore (savePlanSnapshot)
import Core.ProjectStore (ensureProject, recordProjectSession)
import Core.Transcript (listLocalSessions, listLocalSessionsIn, loadTranscript, recordChunk, recordSession, recordToolEvent, recordUser)
import UI.Commands (executeCommand, runSettingsCommand, runLocalShell, resumeSessions, resumeMessages)
import Config.Settings (resolveConfig, saveConfig)
import Data.IORef (newIORef, readIORef)
import Data.List (intersperse, find)
import Data.Maybe (fromMaybe, isJust, isNothing, listToMaybe)
import Data.Text (Text)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Time.LocalTime (TimeZone, getCurrentTimeZone, utcToZonedTime)
import Data.Time.Format (formatTime, defaultTimeLocale)
import UI.Brick.Draw.Dialog (drawDialog, drawPalette, drawWizard, wizardSummary)
import UI.Selection (inSelRange)
import UI.Brick.Toast (showToast)
import UI.Brick.Chat (handleChatWith)
import UI.Brick.ChatKeys (editDefaultKey, handleChatEnter, handleChatKey)
import UI.Brick.AppEvent (handleAppEvent, toCardStatus)
import UI.Brick.Slash (handleSlash)
import UI.Brick.MessageOps (appendMsg, now, setWindowTitle)
import UI.Brick.Draw.Settings (drawSettingsPanel, settingsListMax, settingsRows, visibleRows)
import UI.Brick.Draw.Sidebar (drawCompletion, drawSidebar, sidebarDataFor)
import UI.PasteFold (expandPastes, isLongPaste, pasteLabel)
import UI.TextWidth (takeCells)
import UI.TimeStamp (clockWithZone)
import UI.Render.Footer (footerHints)
import System.Directory (getCurrentDirectory, createDirectoryIfMissing, getHomeDirectory, doesFileExist, getTemporaryDirectory, removeFile, getFileSize)
import Numeric (showFFloat)
import Text.Read (readMaybe)
import System.IO (hFlush, hPutStr, stdout, stderr, openTempFile, hClose, hIsTerminalDevice)
import System.Process (readProcessWithExitCode)
import Control.Exception (IOException, SomeException, catch, try)
import UI.Render.Settings (computeStatsBlocks, renderStatsBlocks, renderStatusRows)
import Data.Time.Clock (UTCTime, diffUTCTime)
import Core.EffortContract (levelsFor)
import UI.Render.ToolSummary (toolHeadline, toolDetailLines, presentCard, shouldHideTool)
import UI.Render.FilePart (filePartsOf, stripFileTokens, filePartLine)
import UI.Render.Message (classifyError, errorLabel, errorHint, metaLine)
```

恢复：`git show 4185dda 58e0566 db89e3c -- "packages/app/CLI/UI/Brick.hs" | grep "^+import"`

### `packages/app/CLI/UI/Brick/AppEvent.hs`

```haskell
import Brick.Widgets.Center (centerLayer)
import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar, tryPutMVar)
import Control.Concurrent.Async (async)
import Control.Monad (filterM, forM_, forever, unless, void, when)
import Control.Monad.IO.Class (liftIO)
import System.Timeout (timeout)
import Core.Clipboard (readClipboardText, saveClipboardImage)
import Core.Bootstrap (ensureBackend)
import Core.RunState (stopAll, stopResultText)
import Core.Export (exportMarkdown, exportJson, defaultExportName)
import Core.PlanStore (savePlanSnapshot)
import Core.ProjectStore (ensureProject, recordProjectSession)
import Core.Transcript (listLocalSessions, listLocalSessionsIn, loadTranscript, recordChunk, recordSession, recordToolEvent, recordUser)
import UI.Commands (executeCommand, runSettingsCommand, runLocalShell, resumeSessions, resumeMessages)
import Config.Settings (resolveConfig, saveConfig)
import Data.IORef (newIORef, readIORef)
import Data.List (intersperse, find)
import Data.Maybe (fromMaybe, isJust, isNothing, listToMaybe)
import Data.Text (Text)
import Data.Time.Clock (UTCTime, diffUTCTime, getCurrentTime)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Time.LocalTime (TimeZone, getCurrentTimeZone, utcToZonedTime)
import Data.Time.Format (formatTime, defaultTimeLocale)
import Graphics.Vty.Config (defaultConfig)
import Graphics.Vty.CrossPlatform (mkVty)
import UI.Brick.Draw.Dialog (drawDialog, drawPalette, drawWizard, wizardSummary)
import UI.Selection (inSelRange)
import UI.Brick.Toast (showToast)
import UI.Brick.Chat (handleChatWith)
import UI.Brick.ChatKeys (editDefaultKey, handleChatEnter, handleChatKey)
import UI.Brick.Slash (handleSlash)
import UI.Brick.MessageOps (appendMsg, now, setWindowTitle)
import UI.Brick.Draw.Settings (drawSettingsPanel, settingsListMax, settingsRows, visibleRows)
import UI.Brick.Draw.Sidebar (drawCompletion, drawSidebar, sidebarDataFor)
import UI.PasteFold (expandPastes, isLongPaste, pasteLabel)
import UI.TextWidth (takeCells)
import UI.TimeStamp (clockWithZone)
import UI.Render.Footer (footerHints)
import System.Directory (getCurrentDirectory, createDirectoryIfMissing, getHomeDirectory, doesFileExist, getTemporaryDirectory, removeFile, getFileSize)
import Numeric (showFFloat)
import Text.Read (readMaybe)
import System.Environment (getEnvironment, lookupEnv)
import System.IO (hFlush, hPutStr, stdout, stderr, openTempFile, hClose, hIsTerminalDevice)
import System.Process (readProcessWithExitCode)
import Control.Exception (IOException, SomeException, catch, try)
import Core.RunLog (logLine)
import UI.ModelPrefs (orderedModels)
import UI.Render.Message (metaLine)
import UI.Render.Settings (computeStatsBlocks, renderStatsBlocks, renderStatusRows)
import UI.IndexCache (scanProjectCached)
```

恢复：`git show 4185dda 58e0566 db89e3c -- "packages/app/CLI/UI/Brick/AppEvent.hs" | grep "^+import"`

### `packages/app/CLI/UI/Brick/AppEvent/Model.hs`

```haskell
import Brick.Widgets.Center (centerLayer)
import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar, tryPutMVar)
import Control.Concurrent.Async (async)
import Data.Foldable (msum)
import Control.Monad (filterM, forM_, forever, unless, void, when)
import System.Timeout (timeout)
import Core.Clipboard (readClipboardText, saveClipboardImage)
import Core.Bootstrap (ensureBackend)
import Core.RunState (stopAll, stopResultText)
import Core.Export (exportMarkdown, exportJson, defaultExportName)
import Core.PlanStore (savePlanSnapshot)
import Core.ProjectStore (ensureProject, recordProjectSession)
import Core.Transcript (listLocalSessions, listLocalSessionsIn, loadTranscript, recordChunk, recordSession, recordToolEvent, recordUser)
import UI.Commands (executeCommand, runSettingsCommand, runLocalShell, resumeSessions, resumeMessages)
import Config.Settings (resolveConfig, saveConfig)
import Data.IORef (newIORef, readIORef)
import Data.List (intersperse, find)
import Data.Maybe (fromMaybe, isJust, isNothing, listToMaybe)
import Data.Text (Text)
import Data.Time.Clock (UTCTime, diffUTCTime, getCurrentTime)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Time.LocalTime (TimeZone, getCurrentTimeZone, utcToZonedTime)
import Data.Time.Format (formatTime, defaultTimeLocale)
import Graphics.Vty.Config (defaultConfig)
import Graphics.Vty.CrossPlatform (mkVty)
import UI.Brick.Draw.Dialog (drawDialog, drawPalette, drawWizard, wizardSummary)
import UI.Selection (inSelRange)
import UI.Brick.Chat (handleChatWith)
import UI.Brick.AppEvent.Sidebar (handleSidebarEvent)
import UI.Brick.AppEvent.Status (handleStatusEvent)
import UI.Brick.AppEvent.Toast (handleToastEvent)
import UI.Brick.ChatKeys (editDefaultKey, handleChatEnter, handleChatKey)
import UI.Brick.Slash (handleSlash)
import UI.Brick.MessageOps (appendMsg, now, setWindowTitle)
import UI.Brick.Draw.Settings (drawSettingsPanel, settingsListMax, settingsRows, visibleRows)
import UI.Brick.Draw.Sidebar (drawCompletion, drawSidebar, sidebarDataFor)
import UI.PasteFold (expandPastes, isLongPaste, pasteLabel)
import UI.TextWidth (takeCells)
import UI.TimeStamp (clockWithZone)
import UI.Render.Footer (footerHints)
import System.Directory (getCurrentDirectory, createDirectoryIfMissing, getHomeDirectory, doesFileExist, getTemporaryDirectory, removeFile, getFileSize)
import Numeric (showFFloat)
import Text.Read (readMaybe)
import System.Environment (getEnvironment, lookupEnv)
import System.IO (hFlush, hPutStr, stdout, stderr, openTempFile, hClose, hIsTerminalDevice)
import System.Process (readProcessWithExitCode)
import Control.Exception (IOException, SomeException, catch, try)
import Core.RunLog (logLine)
import UI.Render.Message (metaLine)
import UI.Render.Settings (computeStatsBlocks, renderStatsBlocks, renderStatusRows)
import UI.IndexCache (scanProjectCached)
```

恢复：`git show 4185dda 58e0566 db89e3c -- "packages/app/CLI/UI/Brick/AppEvent/Model.hs" | grep "^+import"`

### `packages/app/CLI/UI/Brick/AppEvent/Plan.hs`

```haskell
import Brick.Widgets.Center (centerLayer)
import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar, tryPutMVar)
import Control.Concurrent.Async (async)
import Data.Foldable (msum)
import Control.Monad (filterM, forM_, forever, unless, void, when)
import System.Timeout (timeout)
import Core.Clipboard (readClipboardText, saveClipboardImage)
import Core.Bootstrap (ensureBackend)
import Core.RunState (stopAll, stopResultText)
import Core.Export (exportMarkdown, exportJson, defaultExportName)
import Core.ProjectStore (ensureProject, recordProjectSession)
import Core.Transcript (listLocalSessions, listLocalSessionsIn, loadTranscript, recordChunk, recordSession, recordToolEvent, recordUser)
import UI.Commands (executeCommand, runSettingsCommand, runLocalShell, resumeSessions, resumeMessages)
import Config.Settings (resolveConfig, saveConfig)
import Data.IORef (newIORef, readIORef)
import Data.List (intersperse, find)
import Data.Maybe (fromMaybe, isJust, isNothing, listToMaybe)
import Data.Time.Clock (UTCTime, diffUTCTime, getCurrentTime)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Time.LocalTime (TimeZone, getCurrentTimeZone, utcToZonedTime)
import Data.Time.Format (formatTime, defaultTimeLocale)
import Graphics.Vty.Config (defaultConfig)
import Graphics.Vty.CrossPlatform (mkVty)
import UI.Brick.Draw.Dialog (drawDialog, drawPalette, drawWizard, wizardSummary)
import UI.Selection (inSelRange)
import UI.Brick.Chat (handleChatWith)
import UI.Brick.AppEvent.Model (handleModelEvent)
import UI.Brick.AppEvent.Sidebar (handleSidebarEvent)
import UI.Brick.AppEvent.Status (handleStatusEvent)
import UI.Brick.AppEvent.Toast (handleToastEvent)
import UI.Brick.ChatKeys (editDefaultKey, handleChatEnter, handleChatKey)
import UI.Brick.Slash (handleSlash)
import UI.Brick.MessageOps (appendMsg, now, setWindowTitle)
import UI.Brick.Draw.Settings (drawSettingsPanel, settingsListMax, settingsRows, visibleRows)
import UI.Brick.Draw.Sidebar (drawCompletion, drawSidebar, sidebarDataFor)
import UI.PasteFold (expandPastes, isLongPaste, pasteLabel)
import UI.TextWidth (takeCells)
import UI.TimeStamp (clockWithZone)
import UI.Render.Footer (footerHints)
import System.Directory (getCurrentDirectory, createDirectoryIfMissing, getHomeDirectory, doesFileExist, getTemporaryDirectory, removeFile, getFileSize)
import Numeric (showFFloat)
import Text.Read (readMaybe)
import System.Environment (getEnvironment, lookupEnv)
import System.IO (hFlush, hPutStr, stdout, stderr, openTempFile, hClose, hIsTerminalDevice)
import System.Process (readProcessWithExitCode)
import Control.Exception (IOException, SomeException, catch, try)
import Core.RunLog (logLine)
import UI.ModelPrefs (orderedModels)
import UI.Render.Message (metaLine)
import UI.Render.Settings (computeStatsBlocks, renderStatsBlocks, renderStatusRows)
import UI.IndexCache (scanProjectCached)
```

恢复：`git show 4185dda 58e0566 db89e3c -- "packages/app/CLI/UI/Brick/AppEvent/Plan.hs" | grep "^+import"`

### `packages/app/CLI/UI/Brick/AppEvent/Session.hs`

```haskell
import Brick.Widgets.Center (centerLayer)
import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar, tryPutMVar)
import Control.Concurrent.Async (async)
import Data.Foldable (msum)
import Control.Monad (filterM, forM_, forever, unless, void, when)
import System.Timeout (timeout)
import Core.Clipboard (readClipboardText, saveClipboardImage)
import Core.Bootstrap (ensureBackend)
import Core.RunState (stopAll, stopResultText)
import Core.Export (exportMarkdown, exportJson, defaultExportName)
import Core.PlanStore (savePlanSnapshot)
import Core.ProjectStore (ensureProject, recordProjectSession)
import Core.Transcript (listLocalSessions, listLocalSessionsIn, loadTranscript, recordChunk, recordSession, recordToolEvent, recordUser)
import UI.Commands (executeCommand, runSettingsCommand, runLocalShell, resumeSessions, resumeMessages)
import Config.Settings (resolveConfig, saveConfig)
import Data.IORef (newIORef, readIORef)
import Data.List (intersperse, find)
import Data.Maybe (fromMaybe, isJust, isNothing, listToMaybe)
import Data.Text (Text)
import Data.Time.Clock (UTCTime, diffUTCTime, getCurrentTime)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Time.LocalTime (TimeZone, getCurrentTimeZone, utcToZonedTime)
import Data.Time.Format (formatTime, defaultTimeLocale)
import Graphics.Vty.Config (defaultConfig)
import Graphics.Vty.CrossPlatform (mkVty)
import UI.Brick.Draw.Dialog (drawDialog, drawPalette, drawWizard, wizardSummary)
import UI.Selection (inSelRange)
import UI.Brick.Chat (handleChatWith)
import UI.Brick.AppEvent.Model (handleModelEvent)
import UI.Brick.AppEvent.Plan (handlePlanEvent)
import UI.Brick.AppEvent.Sidebar (handleSidebarEvent)
import UI.Brick.AppEvent.Status (handleStatusEvent)
import UI.Brick.AppEvent.Toast (handleToastEvent)
import UI.Brick.ChatKeys (editDefaultKey, handleChatEnter, handleChatKey)
import UI.Brick.Slash (handleSlash)
import UI.Brick.Draw.Settings (drawSettingsPanel, settingsListMax, settingsRows, visibleRows)
import UI.Brick.Draw.Sidebar (drawCompletion, drawSidebar, sidebarDataFor)
import UI.PasteFold (expandPastes, isLongPaste, pasteLabel)
import UI.TextWidth (takeCells)
import UI.TimeStamp (clockWithZone)
import UI.Render.Footer (footerHints)
import System.Directory (getCurrentDirectory, createDirectoryIfMissing, getHomeDirectory, doesFileExist, getTemporaryDirectory, removeFile, getFileSize)
import Numeric (showFFloat)
import Text.Read (readMaybe)
import System.Environment (getEnvironment, lookupEnv)
import System.IO (hFlush, hPutStr, stdout, stderr, openTempFile, hClose, hIsTerminalDevice)
import System.Process (readProcessWithExitCode)
import Control.Exception (IOException, SomeException, catch, try)
import Core.RunLog (logLine)
import UI.ModelPrefs (orderedModels)
import UI.Render.Message (metaLine)
import UI.Render.Settings (computeStatsBlocks, renderStatsBlocks, renderStatusRows)
import UI.IndexCache (scanProjectCached)
```

恢复：`git show 4185dda 58e0566 db89e3c -- "packages/app/CLI/UI/Brick/AppEvent/Session.hs" | grep "^+import"`

### `packages/app/CLI/UI/Brick/AppEvent/Sidebar.hs`

```haskell
import Brick.Widgets.Center (centerLayer)
import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar, tryPutMVar)
import Control.Concurrent.Async (async)
import Control.Monad (filterM, forM_, forever, unless, void, when)
import Control.Monad.IO.Class (liftIO)
import System.Timeout (timeout)
import Core.Clipboard (readClipboardText, saveClipboardImage)
import Core.Bootstrap (ensureBackend)
import Core.RunState (stopAll, stopResultText)
import Core.Export (exportMarkdown, exportJson, defaultExportName)
import Core.PlanStore (savePlanSnapshot)
import Core.ProjectStore (ensureProject, recordProjectSession)
import Core.Transcript (listLocalSessions, listLocalSessionsIn, loadTranscript, recordChunk, recordSession, recordToolEvent, recordUser)
import UI.Commands (executeCommand, runSettingsCommand, runLocalShell, resumeSessions, resumeMessages)
import Config.Settings (resolveConfig, saveConfig)
import Data.IORef (newIORef, readIORef)
import Data.List (intersperse, find)
import Data.Maybe (fromMaybe, isJust, isNothing, listToMaybe)
import Data.Text (Text)
import Data.Time.Clock (UTCTime, diffUTCTime, getCurrentTime)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Time.LocalTime (TimeZone, getCurrentTimeZone, utcToZonedTime)
import Data.Time.Format (formatTime, defaultTimeLocale)
import Graphics.Vty.Config (defaultConfig)
import Graphics.Vty.CrossPlatform (mkVty)
import UI.Brick.Draw.Dialog (drawDialog, drawPalette, drawWizard, wizardSummary)
import UI.Selection (inSelRange)
import UI.Brick.Toast (showToast)
import UI.Brick.Chat (handleChatWith)
import UI.Brick.ChatKeys (editDefaultKey, handleChatEnter, handleChatKey)
import UI.Brick.Slash (handleSlash)
import UI.Brick.MessageOps (appendMsg, now, setWindowTitle)
import UI.Brick.Draw.Settings (drawSettingsPanel, settingsListMax, settingsRows, visibleRows)
import UI.Brick.Draw.Sidebar (drawCompletion, drawSidebar, sidebarDataFor)
import UI.PasteFold (expandPastes, isLongPaste, pasteLabel)
import UI.TextWidth (takeCells)
import UI.TimeStamp (clockWithZone)
import UI.Render.Footer (footerHints)
import System.Directory (getCurrentDirectory, createDirectoryIfMissing, getHomeDirectory, doesFileExist, getTemporaryDirectory, removeFile, getFileSize)
import Numeric (showFFloat)
import Text.Read (readMaybe)
import System.Environment (getEnvironment, lookupEnv)
import System.IO (hFlush, hPutStr, stdout, stderr, openTempFile, hClose, hIsTerminalDevice)
import System.Process (readProcessWithExitCode)
import Control.Exception (IOException, SomeException, catch, try)
import Core.RunLog (logLine)
import UI.ModelPrefs (orderedModels)
import UI.Render.Message (metaLine)
import UI.Render.Settings (computeStatsBlocks, renderStatsBlocks, renderStatusRows)
import UI.IndexCache (scanProjectCached)
```

恢复：`git show 4185dda 58e0566 db89e3c -- "packages/app/CLI/UI/Brick/AppEvent/Sidebar.hs" | grep "^+import"`

### `packages/app/CLI/UI/Brick/AppEvent/Status.hs`

```haskell
import Brick.Widgets.Center (centerLayer)
import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar, tryPutMVar)
import Control.Concurrent.Async (async)
import Control.Monad (filterM, forM_, forever, unless, void, when)
import Control.Monad.IO.Class (liftIO)
import System.Timeout (timeout)
import Core.Clipboard (readClipboardText, saveClipboardImage)
import Core.Bootstrap (ensureBackend)
import Core.RunState (stopAll, stopResultText)
import Core.Export (exportMarkdown, exportJson, defaultExportName)
import Core.PlanStore (savePlanSnapshot)
import Core.ProjectStore (ensureProject, recordProjectSession)
import Core.Transcript (listLocalSessions, listLocalSessionsIn, loadTranscript, recordChunk, recordSession, recordToolEvent, recordUser)
import UI.Commands (executeCommand, runSettingsCommand, runLocalShell, resumeSessions, resumeMessages)
import Config.Settings (resolveConfig, saveConfig)
import Data.IORef (newIORef, readIORef)
import Data.List (intersperse, find)
import Data.Maybe (fromMaybe, isJust, isNothing, listToMaybe)
import Data.Text (Text)
import Data.Time.Clock (UTCTime, diffUTCTime, getCurrentTime)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Time.LocalTime (TimeZone, getCurrentTimeZone, utcToZonedTime)
import Data.Time.Format (formatTime, defaultTimeLocale)
import Graphics.Vty.Config (defaultConfig)
import Graphics.Vty.CrossPlatform (mkVty)
import UI.Brick.Draw.Dialog (drawDialog, drawPalette, drawWizard, wizardSummary)
import UI.Selection (inSelRange)
import UI.Brick.Toast (showToast)
import UI.Brick.Chat (handleChatWith)
import UI.Brick.ChatKeys (editDefaultKey, handleChatEnter, handleChatKey)
import UI.Brick.Slash (handleSlash)
import UI.Brick.MessageOps (appendMsg, now, setWindowTitle)
import UI.Brick.Draw.Settings (drawSettingsPanel, settingsListMax, settingsRows, visibleRows)
import UI.Brick.Draw.Sidebar (drawCompletion, drawSidebar, sidebarDataFor)
import UI.PasteFold (expandPastes, isLongPaste, pasteLabel)
import UI.TextWidth (takeCells)
import UI.TimeStamp (clockWithZone)
import UI.Render.Footer (footerHints)
import System.Directory (getCurrentDirectory, createDirectoryIfMissing, getHomeDirectory, doesFileExist, getTemporaryDirectory, removeFile, getFileSize)
import Numeric (showFFloat)
import Text.Read (readMaybe)
import System.Environment (getEnvironment, lookupEnv)
import System.IO (hFlush, hPutStr, stdout, stderr, openTempFile, hClose, hIsTerminalDevice)
import System.Process (readProcessWithExitCode)
import Control.Exception (IOException, SomeException, catch, try)
import Core.RunLog (logLine)
import UI.ModelPrefs (orderedModels)
import UI.Render.Message (metaLine)
import UI.Render.Settings (computeStatsBlocks, renderStatsBlocks, renderStatusRows)
import UI.IndexCache (scanProjectCached)
```

恢复：`git show 4185dda 58e0566 db89e3c -- "packages/app/CLI/UI/Brick/AppEvent/Status.hs" | grep "^+import"`

### `packages/app/CLI/UI/Brick/AppEvent/Toast.hs`

```haskell
import Brick.Widgets.Center (centerLayer)
import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar, tryPutMVar)
import Control.Concurrent.Async (async)
import Control.Monad (filterM, forM_, forever, unless, void, when)
import System.Timeout (timeout)
import Core.Clipboard (readClipboardText, saveClipboardImage)
import Core.Bootstrap (ensureBackend)
import Core.RunState (stopAll, stopResultText)
import Core.Export (exportMarkdown, exportJson, defaultExportName)
import Core.PlanStore (savePlanSnapshot)
import Core.ProjectStore (ensureProject, recordProjectSession)
import Core.Transcript (listLocalSessions, listLocalSessionsIn, loadTranscript, recordChunk, recordSession, recordToolEvent, recordUser)
import UI.Commands (executeCommand, runSettingsCommand, runLocalShell, resumeSessions, resumeMessages)
import Config.Settings (resolveConfig, saveConfig)
import Data.IORef (newIORef, readIORef)
import Data.List (intersperse, find)
import Data.Maybe (fromMaybe, isJust, isNothing, listToMaybe)
import Data.Text (Text)
import Data.Time.Clock (UTCTime, diffUTCTime, getCurrentTime)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Time.LocalTime (TimeZone, getCurrentTimeZone, utcToZonedTime)
import Data.Time.Format (formatTime, defaultTimeLocale)
import Graphics.Vty.Config (defaultConfig)
import Graphics.Vty.CrossPlatform (mkVty)
import UI.Brick.Draw.Dialog (drawDialog, drawPalette, drawWizard, wizardSummary)
import UI.Selection (inSelRange)
import UI.Brick.Chat (handleChatWith)
import UI.Brick.ChatKeys (editDefaultKey, handleChatEnter, handleChatKey)
import UI.Brick.Slash (handleSlash)
import UI.Brick.MessageOps (appendMsg, now, setWindowTitle)
import UI.Brick.Draw.Settings (drawSettingsPanel, settingsListMax, settingsRows, visibleRows)
import UI.Brick.Draw.Sidebar (drawCompletion, drawSidebar, sidebarDataFor)
import UI.PasteFold (expandPastes, isLongPaste, pasteLabel)
import UI.TextWidth (takeCells)
import UI.TimeStamp (clockWithZone)
import UI.Render.Footer (footerHints)
import System.Directory (getCurrentDirectory, createDirectoryIfMissing, getHomeDirectory, doesFileExist, getTemporaryDirectory, removeFile, getFileSize)
import Numeric (showFFloat)
import Text.Read (readMaybe)
import System.Environment (getEnvironment, lookupEnv)
import System.IO (hFlush, hPutStr, stdout, stderr, openTempFile, hClose, hIsTerminalDevice)
import System.Process (readProcessWithExitCode)
import Control.Exception (IOException, SomeException, catch, try)
import Core.RunLog (logLine)
import UI.ModelPrefs (orderedModels)
import UI.Render.Message (metaLine)
import UI.Render.Settings (computeStatsBlocks, renderStatsBlocks, renderStatusRows)
import UI.IndexCache (scanProjectCached)
```

恢复：`git show 4185dda 58e0566 db89e3c -- "packages/app/CLI/UI/Brick/AppEvent/Toast.hs" | grep "^+import"`

### `packages/app/CLI/UI/Brick/ChatKeys.hs`

```haskell
import Brick.Widgets.Center (centerLayer)
import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar, tryPutMVar)
import Control.Concurrent.Async (async)
import Control.Monad (filterM, forM_, forever, unless, void, when)
import Control.Monad.IO.Class (liftIO)
import System.Timeout (timeout)
import Core.Clipboard (readClipboardText, saveClipboardImage)
import Core.Bootstrap (ensureBackend)
import Core.RunState (stopAll, stopResultText)
import Core.Export (exportMarkdown, exportJson, defaultExportName)
import Core.PlanStore (savePlanSnapshot)
import Core.ProjectStore (ensureProject, recordProjectSession)
import Core.Transcript (listLocalSessions, listLocalSessionsIn, loadTranscript, recordChunk, recordSession, recordToolEvent, recordUser)
import UI.Commands (executeCommand, runSettingsCommand, runLocalShell, resumeSessions, resumeMessages)
import UI.Render.Picker (filterItems)
import Config.Settings (resolveConfig, saveConfig)
import Data.IORef (newIORef, readIORef)
import Data.List (intersperse, find)
import Data.Maybe (fromMaybe, isJust, isNothing, listToMaybe)
import Data.Time.Clock (getCurrentTime)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Time.LocalTime (TimeZone, getCurrentTimeZone, utcToZonedTime)
import Data.Time.Format (formatTime, defaultTimeLocale)
import Graphics.Vty.Config (defaultConfig)
import Graphics.Vty.CrossPlatform (mkVty)
import UI.Brick.Draw.Dialog (drawDialog, drawPalette, drawWizard, wizardSummary)
import UI.Selection (inSelRange)
import UI.Brick.Chat (handleChatWith)
import UI.Brick.Slash (handleSlash)
import UI.Brick.MessageOps (appendMsg, now, setWindowTitle)
import UI.Brick.Draw.Settings (drawSettingsPanel, settingsListMax, settingsRows, visibleRows)
import UI.Brick.Draw.Sidebar (drawCompletion, drawSidebar, sidebarDataFor)
import UI.PasteFold (expandPastes, isLongPaste, pasteLabel)
import UI.TextWidth (takeCells)
import UI.TimeStamp (clockWithZone)
import UI.Render.Footer (footerHints)
import System.Directory (getCurrentDirectory, createDirectoryIfMissing, getHomeDirectory, doesFileExist, getTemporaryDirectory, removeFile, getFileSize)
import Numeric (showFFloat)
import Text.Read (readMaybe)
import System.Environment (getEnvironment, lookupEnv)
import System.IO (hFlush, hPutStr, stdout, stderr, openTempFile, hClose, hIsTerminalDevice)
import System.Process (readProcessWithExitCode)
import Control.Exception (IOException, SomeException, catch, try)
import Core.RunLog (logLine)
import UI.Render.Settings (computeStatsBlocks, renderStatsBlocks, renderStatusRows)
import UI.IndexCache (scanProjectCached)
import Data.Time.Clock (UTCTime, diffUTCTime)
```

恢复：`git show 4185dda 58e0566 db89e3c -- "packages/app/CLI/UI/Brick/ChatKeys.hs" | grep "^+import"`

### `packages/app/CLI/UI/Brick/ChatSubmit.hs`

```haskell
import Brick.Widgets.Center (centerLayer)
import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar, tryPutMVar)
import Control.Concurrent.Async (async)
import Control.Monad (filterM, forM_, forever, unless, void, when)
import System.Timeout (timeout)
import Core.Clipboard (readClipboardText, saveClipboardImage)
import Core.Bootstrap (ensureBackend)
import Core.RunState (stopAll, stopResultText)
import Core.Export (exportMarkdown, exportJson, defaultExportName)
import Core.PlanStore (savePlanSnapshot)
import Core.ProjectStore (ensureProject, recordProjectSession)
import Core.Transcript (listLocalSessions, listLocalSessionsIn, loadTranscript, recordChunk, recordSession, recordToolEvent, recordUser)
import UI.Commands (executeCommand, runSettingsCommand, runLocalShell, resumeSessions, resumeMessages)
import Config.Settings (resolveConfig, saveConfig)
import Data.IORef (newIORef, readIORef)
import Data.List (intersperse, find)
import Data.Maybe (fromMaybe, isJust, isNothing, listToMaybe)
import Data.Time.Clock (getCurrentTime)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Time.LocalTime (TimeZone, getCurrentTimeZone, utcToZonedTime)
import Data.Time.Format (formatTime, defaultTimeLocale)
import Graphics.Vty.Config (defaultConfig)
import Graphics.Vty.CrossPlatform (mkVty)
import UI.Brick.Draw.Dialog (drawDialog, drawPalette, drawWizard, wizardSummary)
import UI.Selection (inSelRange)
import UI.Brick.Toast (showToast)
import UI.Brick.MessageOps (appendMsg, now, setWindowTitle)
import UI.Brick.Draw.Settings (drawSettingsPanel, settingsListMax, settingsRows, visibleRows)
import UI.Brick.Draw.Sidebar (drawCompletion, drawSidebar, sidebarDataFor)
import UI.PasteFold (expandPastes, isLongPaste, pasteLabel)
import UI.TextWidth (takeCells)
import UI.TimeStamp (clockWithZone)
import UI.Render.Footer (footerHints)
import System.Directory (getCurrentDirectory, createDirectoryIfMissing, getHomeDirectory, doesFileExist, getTemporaryDirectory, removeFile, getFileSize)
import Numeric (showFFloat)
import Text.Read (readMaybe)
import System.Environment (getEnvironment, lookupEnv)
import System.IO (hFlush, hPutStr, stdout, stderr, openTempFile, hClose, hIsTerminalDevice)
import System.Process (readProcessWithExitCode)
import Control.Exception (IOException, SomeException, catch, try)
import Core.RunLog (logLine)
import UI.Render.Settings (computeStatsBlocks, renderStatsBlocks, renderStatusRows)
import UI.IndexCache (scanProjectCached)
import Data.Time.Clock (UTCTime, diffUTCTime)
```

恢复：`git show 4185dda 58e0566 db89e3c -- "packages/app/CLI/UI/Brick/ChatSubmit.hs" | grep "^+import"`

### `packages/app/CLI/UI/Brick/DialogActivate.hs`

```haskell
import Brick.Widgets.Center (centerLayer)
import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar, tryPutMVar)
import Control.Monad (filterM, forM_, forever, unless, void, when)
import System.Timeout (timeout)
import Core.Clipboard (readClipboardText, saveClipboardImage)
import Core.Bootstrap (ensureBackend)
import Core.RunState (stopAll, stopResultText)
import Core.Export (exportMarkdown, exportJson, defaultExportName)
import Core.PlanStore (savePlanSnapshot)
import Core.ProjectStore (ensureProject, recordProjectSession)
import Core.Transcript (listLocalSessions, listLocalSessionsIn, loadTranscript, recordChunk, recordSession, recordToolEvent, recordUser)
import UI.Commands (executeCommand, runSettingsCommand, runLocalShell, resumeSessions, resumeMessages)
import Config.Settings (resolveConfig, saveConfig)
import Data.IORef (newIORef, readIORef)
import Data.List (intersperse, find)
import Data.Maybe (fromMaybe, isJust, isNothing, listToMaybe)
import Data.Text (Text)
import Data.Time.Clock (getCurrentTime)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Time.LocalTime (TimeZone, getCurrentTimeZone, utcToZonedTime)
import Data.Time.Format (formatTime, defaultTimeLocale)
import Graphics.Vty.Config (defaultConfig)
import Graphics.Vty.CrossPlatform (mkVty)
import UI.Brick.Draw.Dialog (drawDialog, drawPalette, drawWizard, wizardSummary)
import UI.Selection (inSelRange)
import UI.Brick.Toast (showToast)
import UI.Brick.Chat (handleChatWith)
import UI.Brick.MessageOps (appendMsg, now, setWindowTitle)
import UI.Brick.Draw.Settings (drawSettingsPanel, settingsListMax, settingsRows, visibleRows)
import UI.Brick.Draw.Sidebar (drawCompletion, drawSidebar, sidebarDataFor)
import UI.PasteFold (expandPastes, isLongPaste, pasteLabel)
import UI.TextWidth (takeCells)
import UI.TimeStamp (clockWithZone)
import UI.Render.Footer (footerHints)
import System.Directory (getCurrentDirectory, createDirectoryIfMissing, getHomeDirectory, doesFileExist, getTemporaryDirectory, removeFile, getFileSize)
import Numeric (showFFloat)
import Text.Read (readMaybe)
import System.Environment (getEnvironment, lookupEnv)
import System.IO (hFlush, hPutStr, stdout, stderr, openTempFile, hClose, hIsTerminalDevice)
import System.Process (readProcessWithExitCode)
import Control.Exception (IOException, SomeException, catch, try)
import Core.RunLog (logLine)
import UI.Render.Settings (computeStatsBlocks, renderStatsBlocks, renderStatusRows)
import UI.IndexCache (scanProjectCached)
import Data.Time.Clock (UTCTime, diffUTCTime)
import Core.EffortContract (levelsFor)
import UI.Render.ToolSummary (toolHeadline, toolDetailLines, presentCard, shouldHideTool)
```

恢复：`git show 4185dda 58e0566 db89e3c -- "packages/app/CLI/UI/Brick/DialogActivate.hs" | grep "^+import"`

### `packages/app/CLI/UI/Brick/Draw/Home.hs`

```haskell
import Brick.Widgets.Center (centerLayer)
import Data.Maybe (fromMaybe, isJust)
import Data.Time.Clock (UTCTime)
import Brick.Widgets.Edit (getEditContents, renderEditor)
import UI.Brick.Draw.Dialog (drawDialog, drawPalette, drawWizard)
import UI.Brick.Draw.Settings (drawSettingsPanel)
import UI.Brick.Draw.Sidebar (drawCompletion, drawSidebar)
import UI.Brick.Draw.Status (drawStatus)
import UI.Dialog (stackTop)
import UI.Render.FilePart (filePartsOf, filePartLine, stripFileTokens)
import UI.Render.Message (classifyError, errorHint, errorLabel)
import UI.Selection (inSelRange)
```

恢复：`git show 4185dda 58e0566 db89e3c -- "packages/app/CLI/UI/Brick/Draw/Home.hs" | grep "^+import"`

### `packages/app/CLI/UI/Brick/Draw/Input.hs`

```haskell
import Brick.Widgets.Center (centerLayer)
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import Data.Time.Clock (UTCTime)
import UI.Brick.Draw.Dialog (drawDialog, drawPalette, drawWizard)
import UI.Brick.Draw.Home (drawHome, drawPlanCard)
import UI.Brick.Draw.Settings (drawSettingsPanel)
import UI.Brick.Draw.Sidebar (drawCompletion, drawSidebar)
import UI.Brick.Draw.Status (drawStatus)
import UI.Dialog (stackTop)
import UI.I18n (tr)
import UI.Render.FilePart (filePartsOf, filePartLine, stripFileTokens)
import UI.Render.Message (classifyError, errorHint, errorLabel)
import UI.Selection (inSelRange)
```

恢复：`git show 4185dda 58e0566 db89e3c -- "packages/app/CLI/UI/Brick/Draw/Input.hs" | grep "^+import"`

### `packages/app/CLI/UI/Brick/Draw/MessageBody.hs`

```haskell
import Brick.Widgets.Center (centerLayer)
import Data.Maybe (fromMaybe, isJust)
import Data.Time.Clock (UTCTime)
import Brick.Widgets.Edit (getEditContents, renderEditor)
import UI.Brick.Draw.Dialog (drawDialog, drawPalette, drawWizard)
import UI.Brick.Draw.Settings (drawSettingsPanel)
import UI.Brick.Draw.Sidebar (drawCompletion, drawSidebar)
import UI.Brick.Draw.Status (drawStatus)
import UI.Dialog (stackTop)
import UI.I18n (tr)
import UI.Selection (inSelRange)
```

恢复：`git show 4185dda 58e0566 db89e3c -- "packages/app/CLI/UI/Brick/Draw/MessageBody.hs" | grep "^+import"`

### `packages/app/CLI/UI/Brick/Draw/MessageList.hs`

```haskell
import Brick.Widgets.Center (centerLayer)
import Data.Text (Text)
import Data.Time.Clock (UTCTime)
import Brick.Widgets.Edit (getEditContents, renderEditor)
import UI.Brick.Draw.Dialog (drawDialog, drawPalette, drawWizard)
import UI.Brick.Draw.Settings (drawSettingsPanel)
import UI.Brick.Draw.Sidebar (drawCompletion, drawSidebar)
import UI.Brick.Draw.Status (drawStatus)
import UI.Dialog (stackTop)
import UI.I18n (tr)
import UI.Render.FilePart (filePartsOf, filePartLine, stripFileTokens)
import UI.Render.Message (classifyError, errorHint, errorLabel)
```

恢复：`git show 4185dda 58e0566 db89e3c -- "packages/app/CLI/UI/Brick/Draw/MessageList.hs" | grep "^+import"`

### `packages/app/CLI/UI/Brick/Draw/Messages.hs`

```haskell
import Data.Maybe (fromMaybe, isJust)
import Brick.Widgets.Edit (getEditContents, renderEditor)
import UI.I18n (tr)
import UI.Render.FilePart (filePartsOf, filePartLine, stripFileTokens)
import UI.Render.Message (classifyError, errorHint, errorLabel)
import UI.Selection (inSelRange)
```

恢复：`git show 4185dda 58e0566 db89e3c -- "packages/app/CLI/UI/Brick/Draw/Messages.hs" | grep "^+import"`

### `packages/app/CLI/UI/Brick/Draw/Settings.hs`

```haskell
import Data.Text (Text)
```

恢复：`git show 4185dda 58e0566 db89e3c -- "packages/app/CLI/UI/Brick/Draw/Settings.hs" | grep "^+import"`

### `packages/app/CLI/UI/Brick/Draw/Sidebar.hs`

```haskell
import Data.Text (Text)
import UI.I18n (tr)
```

恢复：`git show 4185dda 58e0566 db89e3c -- "packages/app/CLI/UI/Brick/Draw/Sidebar.hs" | grep "^+import"`

### `packages/app/CLI/UI/Brick/Draw/Status.hs`

```haskell
import Numeric (showFFloat)
import UI.I18n (Lang, tr)
import UI.Render.Footer (parseMetrics)
```

恢复：`git show 4185dda 58e0566 db89e3c -- "packages/app/CLI/UI/Brick/Draw/Status.hs" | grep "^+import"`

### `packages/app/CLI/UI/Brick/InputOps.hs`

```haskell
import Brick.Widgets.Center (centerLayer)
import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar, tryPutMVar)
import Control.Concurrent.Async (async)
import Control.Monad (filterM, forM_, forever, unless, void, when)
import System.Timeout (timeout)
import Core.Bootstrap (ensureBackend)
import Core.RunState (stopAll, stopResultText)
import Core.Export (exportMarkdown, exportJson, defaultExportName)
import Core.PlanStore (savePlanSnapshot)
import Core.ProjectStore (ensureProject, recordProjectSession)
import Core.Transcript (listLocalSessions, listLocalSessionsIn, loadTranscript, recordChunk, recordSession, recordToolEvent, recordUser)
import UI.Commands (executeCommand, runSettingsCommand, runLocalShell, resumeSessions, resumeMessages)
import Config.Settings (resolveConfig, saveConfig)
import Data.IORef (newIORef, readIORef)
import Data.List (intersperse, find)
import Data.Maybe (fromMaybe, isJust, isNothing, listToMaybe)
import Data.Time.Clock (getCurrentTime)
import Data.Time.LocalTime (TimeZone, getCurrentTimeZone, utcToZonedTime)
import Data.Time.Format (formatTime, defaultTimeLocale)
import Graphics.Vty.Config (defaultConfig)
import Graphics.Vty.CrossPlatform (mkVty)
import UI.Brick.Draw.Dialog (drawDialog, drawPalette, drawWizard, wizardSummary)
import UI.Selection (inSelRange)
import UI.Brick.Chat (handleChatWith)
import UI.Brick.Slash (handleSlash)
import UI.Brick.MessageOps (appendMsg, now, setWindowTitle)
import UI.Brick.Draw.Settings (drawSettingsPanel, settingsListMax, settingsRows, visibleRows)
import UI.Brick.Draw.Sidebar (drawCompletion, drawSidebar, sidebarDataFor)
import UI.PasteFold (expandPastes, isLongPaste, pasteLabel)
import UI.TextWidth (takeCells)
import UI.TimeStamp (clockWithZone)
import UI.Render.Footer (footerHints)
import System.Directory (getCurrentDirectory, createDirectoryIfMissing, getHomeDirectory, doesFileExist, getTemporaryDirectory, removeFile, getFileSize)
import Numeric (showFFloat)
import Text.Read (readMaybe)
import System.Environment (getEnvironment, lookupEnv)
import System.IO (hFlush, hPutStr, stdout, stderr, openTempFile, hClose, hIsTerminalDevice)
import Control.Exception (IOException, SomeException, catch, try)
import Core.RunLog (logLine)
import UI.Render.Settings (computeStatsBlocks, renderStatsBlocks, renderStatusRows)
import UI.IndexCache (scanProjectCached)
import Data.Time.Clock (UTCTime, diffUTCTime)
import Core.EffortContract (levelsFor)
```

恢复：`git show 4185dda 58e0566 db89e3c -- "packages/app/CLI/UI/Brick/InputOps.hs" | grep "^+import"`

### `packages/app/CLI/UI/Brick/KeyDispatch.hs`

```haskell
import Brick.Widgets.Center (centerLayer)
import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar, tryPutMVar)
import Control.Concurrent.Async (async)
import Control.Monad (filterM, forM_, forever, unless, void, when)
import System.Timeout (timeout)
import Core.Clipboard (readClipboardText, saveClipboardImage)
import Core.Bootstrap (ensureBackend)
import Core.RunState (stopAll, stopResultText)
import Core.Export (exportMarkdown, exportJson, defaultExportName)
import Core.PlanStore (savePlanSnapshot)
import Core.ProjectStore (ensureProject, recordProjectSession)
import Core.Transcript (listLocalSessions, listLocalSessionsIn, loadTranscript, recordChunk, recordSession, recordToolEvent, recordUser)
import UI.Commands (executeCommand, runSettingsCommand, runLocalShell, resumeSessions, resumeMessages)
import Config.Settings (resolveConfig, saveConfig)
import Data.IORef (newIORef, readIORef)
import Data.List (intersperse, find)
import Data.Maybe (fromMaybe, isJust, isNothing, listToMaybe)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Time.LocalTime (TimeZone, getCurrentTimeZone, utcToZonedTime)
import Data.Time.Format (formatTime, defaultTimeLocale)
import Graphics.Vty.Config (defaultConfig)
import Graphics.Vty.CrossPlatform (mkVty)
import UI.Brick.Draw.Dialog (drawDialog, drawPalette, drawWizard, wizardSummary)
import UI.Selection (inSelRange)
import UI.Brick.Toast (showToast)
import UI.Brick.Chat (handleChatWith)
import UI.Render.Picker (filterItems, queryAppend, queryDelete)
import UI.Brick.ChatKeys (editDefaultKey, handleChatEnter, handleChatKey)
import UI.Brick.MessageOps (appendMsg, now, setWindowTitle)
import UI.Brick.Draw.Settings (drawSettingsPanel, settingsListMax, settingsRows, visibleRows)
import UI.Brick.Draw.Sidebar (drawCompletion, drawSidebar, sidebarDataFor)
import UI.PasteFold (expandPastes, isLongPaste, pasteLabel)
import UI.TextWidth (takeCells)
import UI.TimeStamp (clockWithZone)
import UI.Render.Footer (footerHints)
import System.Directory (getCurrentDirectory, createDirectoryIfMissing, getHomeDirectory, doesFileExist, getTemporaryDirectory, removeFile, getFileSize)
import Numeric (showFFloat)
import Text.Read (readMaybe)
import System.Environment (getEnvironment, lookupEnv)
import System.IO (hFlush, hPutStr, stdout, stderr, openTempFile, hClose, hIsTerminalDevice)
import System.Process (readProcessWithExitCode)
import Control.Exception (IOException, SomeException, catch, try)
import Core.RunLog (logLine)
import UI.Render.Settings (computeStatsBlocks, renderStatsBlocks, renderStatusRows)
import UI.IndexCache (scanProjectCached)
import Data.Time.Clock (UTCTime, diffUTCTime)
```

恢复：`git show 4185dda 58e0566 db89e3c -- "packages/app/CLI/UI/Brick/KeyDispatch.hs" | grep "^+import"`

### `packages/app/CLI/UI/Brick/Palette.hs`

```haskell
import Brick.Widgets.Center (centerLayer)
import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar, tryPutMVar)
import Control.Concurrent.Async (async)
import Control.Monad (filterM, forM_, forever, unless, void, when)
import Control.Monad.IO.Class (liftIO)
import System.Timeout (timeout)
import Core.Clipboard (readClipboardText, saveClipboardImage)
import Core.Bootstrap (ensureBackend)
import Core.RunState (stopAll, stopResultText)
import Core.Export (exportMarkdown, exportJson, defaultExportName)
import Core.PlanStore (savePlanSnapshot)
import Core.ProjectStore (ensureProject, recordProjectSession)
import Core.Transcript (listLocalSessions, listLocalSessionsIn, loadTranscript, recordChunk, recordSession, recordToolEvent, recordUser)
import UI.Commands (executeCommand, runSettingsCommand, runLocalShell, resumeSessions, resumeMessages)
import Config.Settings (resolveConfig, saveConfig)
import Data.IORef (newIORef, readIORef)
import Data.List (intersperse, find)
import Data.Maybe (fromMaybe, isJust, isNothing, listToMaybe)
import Data.Text (Text)
import Data.Time.Clock (getCurrentTime)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Time.LocalTime (TimeZone, getCurrentTimeZone, utcToZonedTime)
import Data.Time.Format (formatTime, defaultTimeLocale)
import Graphics.Vty.Config (defaultConfig)
import Graphics.Vty.CrossPlatform (mkVty)
import UI.Brick.Draw.Dialog (drawDialog, drawPalette, drawWizard, wizardSummary)
import UI.Selection (inSelRange)
import UI.Brick.Toast (showToast)
import UI.Brick.Chat (handleChatWith)
import UI.Brick.MessageOps (appendMsg, now, setWindowTitle)
import UI.Brick.Draw.Settings (drawSettingsPanel, settingsListMax, settingsRows, visibleRows)
import UI.Brick.Draw.Sidebar (drawCompletion, drawSidebar, sidebarDataFor)
import UI.PasteFold (expandPastes, isLongPaste, pasteLabel)
import UI.TextWidth (takeCells)
import UI.TimeStamp (clockWithZone)
import UI.Render.Footer (footerHints)
import System.Directory (getCurrentDirectory, createDirectoryIfMissing, getHomeDirectory, doesFileExist, getTemporaryDirectory, removeFile, getFileSize)
import Numeric (showFFloat)
import Text.Read (readMaybe)
import System.Environment (getEnvironment, lookupEnv)
import System.IO (hFlush, hPutStr, stdout, stderr, openTempFile, hClose, hIsTerminalDevice)
import System.Process (readProcessWithExitCode)
import Control.Exception (IOException, SomeException, catch, try)
import Core.RunLog (logLine)
import UI.Render.Settings (computeStatsBlocks, renderStatsBlocks, renderStatusRows)
import UI.IndexCache (scanProjectCached)
import Data.Time.Clock (UTCTime, diffUTCTime)
import Core.EffortContract (levelsFor)
import UI.Render.ToolSummary (toolHeadline, toolDetailLines, presentCard, shouldHideTool)
import UI.Render.FilePart (filePartsOf, stripFileTokens, filePartLine)
import UI.Render.Message (classifyError, errorLabel, errorHint, metaLine)
```

恢复：`git show 4185dda 58e0566 db89e3c -- "packages/app/CLI/UI/Brick/Palette.hs" | grep "^+import"`

### `packages/app/CLI/UI/Brick/SettingsKeys.hs`

```haskell
import Brick.Widgets.Center (centerLayer)
import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar, tryPutMVar)
import Control.Concurrent.Async (async)
import Control.Monad (filterM, forM_, forever, unless, void, when)
import System.Timeout (timeout)
import Core.Clipboard (readClipboardText, saveClipboardImage)
import Core.Bootstrap (ensureBackend)
import Core.RunState (stopAll, stopResultText)
import Core.Export (exportMarkdown, exportJson, defaultExportName)
import Core.PlanStore (savePlanSnapshot)
import Core.ProjectStore (ensureProject, recordProjectSession)
import Core.Transcript (listLocalSessions, listLocalSessionsIn, loadTranscript, recordChunk, recordSession, recordToolEvent, recordUser)
import UI.Commands (executeCommand, runSettingsCommand, runLocalShell, resumeSessions, resumeMessages)
import Config.Settings (resolveConfig, saveConfig)
import Data.IORef (newIORef, readIORef)
import Data.List (intersperse, find)
import Data.Maybe (fromMaybe, isJust, isNothing, listToMaybe)
import Data.Time.Clock (getCurrentTime)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Time.LocalTime (TimeZone, getCurrentTimeZone, utcToZonedTime)
import Data.Time.Format (formatTime, defaultTimeLocale)
import Graphics.Vty.Config (defaultConfig)
import Graphics.Vty.CrossPlatform (mkVty)
import UI.Brick.Draw.Dialog (drawDialog, drawPalette, drawWizard, wizardSummary)
import UI.Selection (inSelRange)
import UI.Brick.Toast (showToast)
import UI.Brick.Chat (handleChatWith)
import UI.Brick.AppEvent (handleAppEvent)
import UI.Render.Picker (filterItems, queryAppend, queryDelete)
import UI.Brick.ChatKeys (editDefaultKey, handleChatEnter, handleChatKey)
import UI.Brick.Slash (handleSlash)
import UI.Brick.MessageOps (appendMsg, now, setWindowTitle)
import UI.Brick.Draw.Settings (drawSettingsPanel, settingsListMax, settingsRows, visibleRows)
import UI.Brick.Draw.Sidebar (drawCompletion, drawSidebar, sidebarDataFor)
import UI.PasteFold (expandPastes, isLongPaste, pasteLabel)
import UI.TextWidth (takeCells)
import UI.TimeStamp (clockWithZone)
import UI.Render.Footer (footerHints)
import System.Directory (getCurrentDirectory, createDirectoryIfMissing, getHomeDirectory, doesFileExist, getTemporaryDirectory, removeFile, getFileSize)
import Numeric (showFFloat)
import Text.Read (readMaybe)
import System.Environment (getEnvironment, lookupEnv)
import System.IO (hFlush, hPutStr, stdout, stderr, openTempFile, hClose, hIsTerminalDevice)
import System.Process (readProcessWithExitCode)
import Control.Exception (IOException, SomeException, catch, try)
import Core.RunLog (logLine)
import UI.Render.Settings (computeStatsBlocks, renderStatsBlocks, renderStatusRows)
import UI.IndexCache (scanProjectCached)
import Data.Time.Clock (UTCTime, diffUTCTime)
```

恢复：`git show 4185dda 58e0566 db89e3c -- "packages/app/CLI/UI/Brick/SettingsKeys.hs" | grep "^+import"`

### `packages/app/CLI/UI/Brick/Slash.hs`

```haskell
import Brick.Widgets.Center (centerLayer)
import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar, tryPutMVar)
import Control.Concurrent.Async (async)
import Control.Monad (filterM, forM_, forever, unless, void, when)
import System.Timeout (timeout)
import Core.Clipboard (readClipboardText, saveClipboardImage)
import Core.Bootstrap (ensureBackend)
import Core.Export (exportMarkdown, exportJson, defaultExportName)
import Core.PlanStore (savePlanSnapshot)
import Core.ProjectStore (ensureProject, recordProjectSession)
import Core.Transcript (listLocalSessions, listLocalSessionsIn, loadTranscript, recordChunk, recordSession, recordToolEvent, recordUser)
import UI.Commands (executeCommand, runSettingsCommand, runLocalShell, resumeSessions, resumeMessages)
import Config.Settings (resolveConfig, saveConfig)
import Data.List (intersperse, find)
import Data.Maybe (fromMaybe, isJust, isNothing, listToMaybe)
import Data.Time.Clock (getCurrentTime)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Time.LocalTime (TimeZone, getCurrentTimeZone, utcToZonedTime)
import Data.Time.Format (formatTime, defaultTimeLocale)
import Graphics.Vty.Config (defaultConfig)
import Graphics.Vty.CrossPlatform (mkVty)
import UI.Brick.Draw.Dialog (drawDialog, drawPalette, drawWizard, wizardSummary)
import UI.Selection (inSelRange)
import UI.Brick.Toast (showToast)
import UI.Brick.MessageOps (appendMsg, now, setWindowTitle)
import UI.Brick.Draw.Settings (drawSettingsPanel, settingsListMax, settingsRows, visibleRows)
import UI.Brick.Draw.Sidebar (drawCompletion, drawSidebar, sidebarDataFor)
import UI.PasteFold (expandPastes, isLongPaste, pasteLabel)
import UI.TextWidth (takeCells)
import UI.TimeStamp (clockWithZone)
import UI.Render.Footer (footerHints)
import System.Directory (getCurrentDirectory, createDirectoryIfMissing, getHomeDirectory, doesFileExist, getTemporaryDirectory, removeFile, getFileSize)
import Numeric (showFFloat)
import Text.Read (readMaybe)
import System.Environment (getEnvironment, lookupEnv)
import System.IO (hFlush, hPutStr, stdout, stderr, openTempFile, hClose, hIsTerminalDevice)
import System.Process (readProcessWithExitCode)
import Control.Exception (IOException, SomeException, catch, try)
import Core.RunLog (logLine)
import UI.Render.Settings (computeStatsBlocks, renderStatsBlocks, renderStatusRows)
import UI.IndexCache (scanProjectCached)
import Data.Time.Clock (UTCTime, diffUTCTime)
import Core.EffortContract (levelsFor)
import UI.Render.ToolSummary (toolHeadline, toolDetailLines, presentCard, shouldHideTool)
import UI.Render.FilePart (filePartsOf, stripFileTokens, filePartLine)
import UI.Render.Message (classifyError, errorLabel, errorHint, metaLine)
```

恢复：`git show 4185dda 58e0566 db89e3c -- "packages/app/CLI/UI/Brick/Slash.hs" | grep "^+import"`

### `packages/app/CLI/UI/Brick/Slash/Config.hs`

```haskell
import Brick.Widgets.Center (centerLayer)
import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar, tryPutMVar)
import Control.Concurrent.Async (async)
import Control.Monad (filterM, forM_, forever, unless, void, when)
import System.Timeout (timeout)
import Core.Clipboard (readClipboardText, saveClipboardImage)
import Core.Bootstrap (ensureBackend)
import Core.RunState (stopAll, stopResultText)
import Core.Export (exportMarkdown, exportJson, defaultExportName)
import Core.PlanStore (savePlanSnapshot)
import Core.ProjectStore (ensureProject, recordProjectSession)
import Core.Transcript (listLocalSessions, listLocalSessionsIn, loadTranscript, recordChunk, recordSession, recordToolEvent, recordUser)
import UI.Commands (executeCommand, runSettingsCommand, runLocalShell, resumeSessions, resumeMessages)
import Data.IORef (newIORef, readIORef)
import Data.List (intersperse, find)
import Data.Foldable (msum)
import Data.Maybe (fromMaybe, isJust, isNothing, listToMaybe)
import Data.Time.Clock (getCurrentTime)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Time.LocalTime (TimeZone, getCurrentTimeZone, utcToZonedTime)
import Data.Time.Format (formatTime, defaultTimeLocale)
import Graphics.Vty.Config (defaultConfig)
import Graphics.Vty.CrossPlatform (mkVty)
import UI.Brick.Draw.Dialog (drawDialog, drawPalette, drawWizard, wizardSummary)
import UI.Selection (inSelRange)
import UI.Brick.Slash.Info (handleInfoSlash)
import UI.Brick.Slash.Lifecycle (handleLifecycleSlash)
import UI.Brick.Slash.Session (handleSessionSlash)
import UI.Brick.Slash.Workspace (handleWorkspaceSlash)
import UI.Brick.Chat (handleChatWith)
import UI.Brick.MessageOps (appendMsg, now, setWindowTitle)
import UI.Brick.Draw.Settings (drawSettingsPanel, settingsListMax, settingsRows, visibleRows)
import UI.Brick.Draw.Sidebar (drawCompletion, drawSidebar, sidebarDataFor)
import UI.PasteFold (expandPastes, isLongPaste, pasteLabel)
import UI.TextWidth (takeCells)
import UI.TimeStamp (clockWithZone)
import UI.Render.Footer (footerHints)
import System.Directory (getCurrentDirectory, createDirectoryIfMissing, getHomeDirectory, doesFileExist, getTemporaryDirectory, removeFile, getFileSize)
import Numeric (showFFloat)
import Text.Read (readMaybe)
import System.Environment (getEnvironment, lookupEnv)
import System.IO (hFlush, hPutStr, stdout, stderr, openTempFile, hClose, hIsTerminalDevice)
import System.Process (readProcessWithExitCode)
import Control.Exception (IOException, SomeException, catch, try)
import Core.RunLog (logLine)
import UI.Render.Settings (computeStatsBlocks, renderStatsBlocks, renderStatusRows)
import UI.IndexCache (scanProjectCached)
import Data.Time.Clock (UTCTime, diffUTCTime)
import Core.EffortContract (levelsFor)
import UI.Render.ToolSummary (toolHeadline, toolDetailLines, presentCard, shouldHideTool)
import UI.Render.FilePart (filePartsOf, stripFileTokens, filePartLine)
import UI.Render.Message (classifyError, errorLabel, errorHint, metaLine)
```

恢复：`git show 4185dda 58e0566 db89e3c -- "packages/app/CLI/UI/Brick/Slash/Config.hs" | grep "^+import"`

### `packages/app/CLI/UI/Brick/Slash/Info.hs`

```haskell
import Data.Text (Text)
```

恢复：`git show 4185dda 58e0566 db89e3c -- "packages/app/CLI/UI/Brick/Slash/Info.hs" | grep "^+import"`

### `packages/app/CLI/UI/Brick/Slash/Session.hs`

```haskell
import Brick.Widgets.Center (centerLayer)
import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar, tryPutMVar)
import Control.Monad (filterM, forM_, forever, unless, void, when)
import System.Timeout (timeout)
import Core.Clipboard (readClipboardText, saveClipboardImage)
import Core.Bootstrap (ensureBackend)
import Core.RunState (stopAll, stopResultText)
import Core.PlanStore (savePlanSnapshot)
import Core.ProjectStore (ensureProject, recordProjectSession)
import Core.Transcript (listLocalSessions, listLocalSessionsIn, loadTranscript, recordChunk, recordSession, recordToolEvent, recordUser)
import UI.Commands (executeCommand, runSettingsCommand, runLocalShell, resumeSessions, resumeMessages)
import Config.Settings (resolveConfig, saveConfig)
import Data.IORef (newIORef, readIORef)
import Data.List (intersperse, find)
import Data.Foldable (msum)
import Data.Maybe (fromMaybe, isJust, isNothing, listToMaybe)
import Data.Text (Text)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Time.LocalTime (TimeZone, getCurrentTimeZone, utcToZonedTime)
import Graphics.Vty.Config (defaultConfig)
import Graphics.Vty.CrossPlatform (mkVty)
import UI.Brick.Draw.Dialog (drawDialog, drawPalette, drawWizard, wizardSummary)
import UI.Selection (inSelRange)
import UI.Brick.Slash.Info (handleInfoSlash)
import UI.Brick.Slash.Lifecycle (handleLifecycleSlash)
import UI.Brick.Chat (handleChatWith)
import UI.Brick.MessageOps (appendMsg, now, setWindowTitle)
import UI.Brick.Draw.Settings (drawSettingsPanel, settingsListMax, settingsRows, visibleRows)
import UI.Brick.Draw.Sidebar (drawCompletion, drawSidebar, sidebarDataFor)
import UI.PasteFold (expandPastes, isLongPaste, pasteLabel)
import UI.TextWidth (takeCells)
import UI.TimeStamp (clockWithZone)
import UI.Render.Footer (footerHints)
import System.Directory (getCurrentDirectory, createDirectoryIfMissing, getHomeDirectory, doesFileExist, getTemporaryDirectory, removeFile, getFileSize)
import Numeric (showFFloat)
import Text.Read (readMaybe)
import System.Environment (getEnvironment, lookupEnv)
import System.IO (hFlush, hPutStr, stdout, stderr, openTempFile, hClose, hIsTerminalDevice)
import System.Process (readProcessWithExitCode)
import Control.Exception (IOException, SomeException, catch, try)
import Core.RunLog (logLine)
import UI.Render.Settings (computeStatsBlocks, renderStatsBlocks, renderStatusRows)
import UI.IndexCache (scanProjectCached)
import Data.Time.Clock (UTCTime, diffUTCTime)
import Core.EffortContract (levelsFor)
import UI.Render.ToolSummary (toolHeadline, toolDetailLines, presentCard, shouldHideTool)
import UI.Render.FilePart (filePartsOf, stripFileTokens, filePartLine)
import UI.Render.Message (classifyError, errorLabel, errorHint, metaLine)
```

恢复：`git show 4185dda 58e0566 db89e3c -- "packages/app/CLI/UI/Brick/Slash/Session.hs" | grep "^+import"`

### `packages/app/CLI/UI/Brick/Slash/Tools.hs`

```haskell
import Data.Text (Text)
```

恢复：`git show 4185dda 58e0566 db89e3c -- "packages/app/CLI/UI/Brick/Slash/Tools.hs" | grep "^+import"`

### `packages/app/CLI/UI/Brick/Slash/Workspace.hs`

```haskell
import Brick.Widgets.Center (centerLayer)
import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar, tryPutMVar)
import Control.Concurrent.Async (async)
import Control.Monad (filterM, forM_, forever, unless, void, when)
import System.Timeout (timeout)
import Core.Clipboard (readClipboardText, saveClipboardImage)
import Core.Bootstrap (ensureBackend)
import Core.RunState (stopAll, stopResultText)
import Core.Export (exportMarkdown, exportJson, defaultExportName)
import Core.PlanStore (savePlanSnapshot)
import Core.ProjectStore (ensureProject, recordProjectSession)
import Core.Transcript (listLocalSessions, listLocalSessionsIn, loadTranscript, recordChunk, recordSession, recordToolEvent, recordUser)
import UI.Commands (executeCommand, runSettingsCommand, runLocalShell, resumeSessions, resumeMessages)
import Config.Settings (resolveConfig, saveConfig)
import Data.IORef (newIORef, readIORef)
import Data.List (intersperse, find)
import Data.Foldable (msum)
import Data.Maybe (fromMaybe, isJust, isNothing, listToMaybe)
import Data.Time.Clock (getCurrentTime)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Time.LocalTime (TimeZone, getCurrentTimeZone, utcToZonedTime)
import Data.Time.Format (formatTime, defaultTimeLocale)
import Graphics.Vty.Config (defaultConfig)
import Graphics.Vty.CrossPlatform (mkVty)
import UI.Brick.Draw.Dialog (drawDialog, drawPalette, drawWizard, wizardSummary)
import UI.Selection (inSelRange)
import UI.Brick.Slash.Info (handleInfoSlash)
import UI.Brick.Slash.Lifecycle (handleLifecycleSlash)
import UI.Brick.Slash.Session (handleSessionSlash)
import UI.Brick.Chat (handleChatWith)
import UI.Brick.MessageOps (appendMsg, now, setWindowTitle)
import UI.Brick.Draw.Settings (drawSettingsPanel, settingsListMax, settingsRows, visibleRows)
import UI.Brick.Draw.Sidebar (drawCompletion, drawSidebar, sidebarDataFor)
import UI.PasteFold (expandPastes, isLongPaste, pasteLabel)
import UI.TimeStamp (clockWithZone)
import UI.Render.Footer (footerHints)
import System.Directory (getCurrentDirectory, createDirectoryIfMissing, getHomeDirectory, doesFileExist, getTemporaryDirectory, removeFile, getFileSize)
import Numeric (showFFloat)
import Text.Read (readMaybe)
import System.Environment (getEnvironment, lookupEnv)
import System.IO (hFlush, hPutStr, stdout, stderr, openTempFile, hClose, hIsTerminalDevice)
import System.Process (readProcessWithExitCode)
import Control.Exception (IOException, SomeException, catch, try)
import Core.RunLog (logLine)
import UI.Render.Settings (computeStatsBlocks, renderStatsBlocks, renderStatusRows)
import UI.IndexCache (scanProjectCached)
import Data.Time.Clock (UTCTime, diffUTCTime)
import Core.EffortContract (levelsFor)
import UI.Render.ToolSummary (toolHeadline, toolDetailLines, presentCard, shouldHideTool)
import UI.Render.FilePart (filePartsOf, stripFileTokens, filePartLine)
import UI.Render.Message (classifyError, errorLabel, errorHint, metaLine)
```

恢复：`git show 4185dda 58e0566 db89e3c -- "packages/app/CLI/UI/Brick/Slash/Workspace.hs" | grep "^+import"`

### `packages/app/CLI/UI/Brick/Stream.hs`

```haskell
import Brick.Widgets.Center (centerLayer)
import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar, tryPutMVar)
import Control.Monad (filterM, forM_, forever, unless, void, when)
import System.Timeout (timeout)
import Core.Clipboard (readClipboardText, saveClipboardImage)
import Core.Bootstrap (ensureBackend)
import Core.RunState (stopAll, stopResultText)
import Core.Export (exportMarkdown, exportJson, defaultExportName)
import Core.PlanStore (savePlanSnapshot)
import Core.ProjectStore (ensureProject, recordProjectSession)
import Core.Transcript (listLocalSessions, listLocalSessionsIn, loadTranscript, recordChunk, recordSession, recordToolEvent, recordUser)
import UI.Commands (executeCommand, runSettingsCommand, runLocalShell, resumeSessions, resumeMessages)
import Config.Settings (resolveConfig, saveConfig)
import Data.IORef (newIORef, readIORef)
import Data.List (intersperse, find)
import Data.Maybe (fromMaybe, isJust, isNothing, listToMaybe)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Time.LocalTime (TimeZone, getCurrentTimeZone, utcToZonedTime)
import Data.Time.Format (formatTime, defaultTimeLocale)
import Graphics.Vty.Config (defaultConfig)
import Graphics.Vty.CrossPlatform (mkVty)
import UI.Brick.Draw.Dialog (drawDialog, drawPalette, drawWizard, wizardSummary)
import UI.Selection (inSelRange)
import UI.Brick.Toast (showToast)
import UI.Brick.Chat (handleChatWith)
import UI.Brick.ChatKeys (editDefaultKey, handleChatEnter, handleChatKey)
import UI.Brick.Slash (handleSlash)
import UI.Brick.MessageOps (appendMsg, now, setWindowTitle)
import UI.Brick.Draw.Settings (drawSettingsPanel, settingsListMax, settingsRows, visibleRows)
import UI.Brick.Draw.Sidebar (drawCompletion, drawSidebar, sidebarDataFor)
import UI.PasteFold (expandPastes, isLongPaste, pasteLabel)
import UI.TextWidth (takeCells)
import UI.TimeStamp (clockWithZone)
import UI.Render.Footer (footerHints)
import System.Directory (getCurrentDirectory, createDirectoryIfMissing, getHomeDirectory, doesFileExist, getTemporaryDirectory, removeFile, getFileSize)
import Numeric (showFFloat)
import Text.Read (readMaybe)
import System.Environment (getEnvironment, lookupEnv)
import System.IO (hFlush, hPutStr, stdout, stderr, openTempFile, hClose, hIsTerminalDevice)
import System.Process (readProcessWithExitCode)
import Control.Exception (IOException, SomeException, catch, try)
import Core.RunLog (logLine)
import UI.ModelPrefs (orderedModels)
import UI.Render.Settings (computeStatsBlocks, renderStatsBlocks, renderStatusRows)
import UI.IndexCache (scanProjectCached)
```

恢复：`git show 4185dda 58e0566 db89e3c -- "packages/app/CLI/UI/Brick/Stream.hs" | grep "^+import"`

### `packages/app/CLI/UI/Brick/ToolCardMsg.hs`

```haskell
import Brick.Widgets.Center (centerLayer)
import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar, tryPutMVar)
import Control.Concurrent.Async (async)
import Control.Monad (filterM, forM_, forever, unless, void, when)
import Control.Monad.IO.Class (liftIO)
import System.Timeout (timeout)
import Core.Clipboard (readClipboardText, saveClipboardImage)
import Core.Bootstrap (ensureBackend)
import Core.RunState (stopAll, stopResultText)
import Core.Export (exportMarkdown, exportJson, defaultExportName)
import Core.PlanStore (savePlanSnapshot)
import Core.ProjectStore (ensureProject, recordProjectSession)
import Core.Transcript (listLocalSessions, listLocalSessionsIn, loadTranscript, recordChunk, recordSession, recordToolEvent, recordUser)
import UI.Commands (executeCommand, runSettingsCommand, runLocalShell, resumeSessions, resumeMessages)
import Config.Settings (resolveConfig, saveConfig)
import Data.IORef (newIORef, readIORef)
import Data.List (intersperse, find)
import Data.Maybe (fromMaybe, isJust, isNothing, listToMaybe)
import Data.Time.Clock (UTCTime, diffUTCTime, getCurrentTime)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Time.LocalTime (TimeZone, getCurrentTimeZone, utcToZonedTime)
import Data.Time.Format (formatTime, defaultTimeLocale)
import Graphics.Vty.Config (defaultConfig)
import Graphics.Vty.CrossPlatform (mkVty)
import UI.Brick.Draw.Dialog (drawDialog, drawPalette, drawWizard, wizardSummary)
import UI.Selection (inSelRange)
import UI.Brick.Toast (showToast)
import UI.Brick.Chat (handleChatWith)
import UI.Brick.ChatKeys (editDefaultKey, handleChatEnter, handleChatKey)
import UI.Brick.Slash (handleSlash)
import UI.Brick.MessageOps (appendMsg, now, setWindowTitle)
import UI.Brick.Draw.Settings (drawSettingsPanel, settingsListMax, settingsRows, visibleRows)
import UI.Brick.Draw.Sidebar (drawCompletion, drawSidebar, sidebarDataFor)
import UI.PasteFold (expandPastes, isLongPaste, pasteLabel)
import UI.TextWidth (takeCells)
import UI.TimeStamp (clockWithZone)
import UI.Render.Footer (footerHints)
import System.Directory (getCurrentDirectory, createDirectoryIfMissing, getHomeDirectory, doesFileExist, getTemporaryDirectory, removeFile, getFileSize)
import Numeric (showFFloat)
import Text.Read (readMaybe)
import System.Environment (getEnvironment, lookupEnv)
import System.IO (hFlush, hPutStr, stdout, stderr, openTempFile, hClose, hIsTerminalDevice)
import System.Process (readProcessWithExitCode)
import Control.Exception (IOException, SomeException, catch, try)
import Core.RunLog (logLine)
import UI.ModelPrefs (orderedModels)
import UI.Render.Message (metaLine)
import UI.Render.Settings (computeStatsBlocks, renderStatsBlocks, renderStatusRows)
import UI.IndexCache (scanProjectCached)
```

恢复：`git show 4185dda 58e0566 db89e3c -- "packages/app/CLI/UI/Brick/ToolCardMsg.hs" | grep "^+import"`

### `packages/app/CLI/UI/Brick/Wizard.hs`

```haskell
import Brick.Widgets.Center (centerLayer)
import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar, tryPutMVar)
import Control.Monad (filterM, forM_, forever, unless, void, when)
import System.Timeout (timeout)
import Core.Clipboard (readClipboardText, saveClipboardImage)
import Core.Bootstrap (ensureBackend)
import Core.RunState (stopAll, stopResultText)
import Core.Export (exportMarkdown, exportJson, defaultExportName)
import Core.PlanStore (savePlanSnapshot)
import Core.ProjectStore (ensureProject, recordProjectSession)
import Core.Transcript (listLocalSessions, listLocalSessionsIn, loadTranscript, recordChunk, recordSession, recordToolEvent, recordUser)
import UI.Commands (executeCommand, runSettingsCommand, runLocalShell, resumeSessions, resumeMessages)
import Config.Settings (resolveConfig, saveConfig)
import Data.IORef (newIORef, readIORef)
import Data.List (intersperse, find)
import Data.Maybe (fromMaybe, isJust, isNothing, listToMaybe)
import Data.Time.Clock (getCurrentTime)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Time.LocalTime (TimeZone, getCurrentTimeZone, utcToZonedTime)
import Data.Time.Format (formatTime, defaultTimeLocale)
import Graphics.Vty.Config (defaultConfig)
import Graphics.Vty.CrossPlatform (mkVty)
import UI.Brick.Draw.Dialog (drawDialog, drawPalette, drawWizard, wizardSummary)
import UI.Selection (inSelRange)
import UI.Brick.Toast (showToast)
import UI.Brick.Chat (handleChatWith)
import UI.Brick.Slash (handleSlash)
import UI.Brick.MessageOps (appendMsg, now, setWindowTitle)
import UI.Brick.Draw.Settings (drawSettingsPanel, settingsListMax, settingsRows, visibleRows)
import UI.Brick.Draw.Sidebar (drawCompletion, drawSidebar, sidebarDataFor)
import UI.PasteFold (expandPastes, isLongPaste, pasteLabel)
import UI.TextWidth (takeCells)
import UI.TimeStamp (clockWithZone)
import UI.Render.Footer (footerHints)
import System.Directory (getCurrentDirectory, createDirectoryIfMissing, getHomeDirectory, doesFileExist, getTemporaryDirectory, removeFile, getFileSize)
import Numeric (showFFloat)
import Text.Read (readMaybe)
import System.Environment (getEnvironment, lookupEnv)
import System.IO (hFlush, hPutStr, stdout, stderr, openTempFile, hClose, hIsTerminalDevice)
import System.Process (readProcessWithExitCode)
import Control.Exception (IOException, SomeException, catch, try)
import Core.RunLog (logLine)
import UI.Render.Settings (computeStatsBlocks, renderStatsBlocks, renderStatusRows)
import UI.IndexCache (scanProjectCached)
import Data.Time.Clock (UTCTime, diffUTCTime)
import Core.EffortContract (levelsFor)
import UI.Render.ToolSummary (toolHeadline, toolDetailLines, presentCard, shouldHideTool)
import UI.Render.FilePart (filePartsOf, stripFileTokens, filePartLine)
import UI.Render.Message (classifyError, errorLabel, errorHint, metaLine)
```

恢复：`git show 4185dda 58e0566 db89e3c -- "packages/app/CLI/UI/Brick/Wizard.hs" | grep "^+import"`

### `packages/app/CLI/UI/Commands.hs`

```haskell
import Data.Char (isHexDigit)
import UI.ProviderPresets (presets, preBaseUrl, preKind, preName)
import Core.Export (exportMarkdown, exportJson, defaultExportName)
import Core.Memory (allMemories, forgetText, rememberText)
import Core.Transcript (listLocalSessions, listLocalSessionsIn, loadTranscript, recordChunk, recordModelRequest, recordSession, recordToolEvent, recordUser)
import Control.Concurrent (threadDelay)
import Control.Exception (IOException, catch, try)
import Data.List (partition, sort)
import System.IO (hClose, hFlush, hPutStr, openTempFile, stdout)
import System.Environment (lookupEnv, getEnvironment)
import Data.Maybe (fromMaybe)
import Core.Clipboard (saveClipboardImage)
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist, getHomeDirectory, getTemporaryDirectory, listDirectory, removeFile)
import System.Process (readProcessWithExitCode, readCreateProcessWithExitCode, proc, env)
import System.Timeout (timeout)
import Data.Time.Clock (getCurrentTime)
import Data.Time.LocalTime (getCurrentTimeZone, utcToZonedTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import System.Directory (createDirectoryIfMissing, getHomeDirectory)
import System.Environment (lookupEnv)
import Text.Read (readMaybe)
import System.Process (callCommand)
import UI.ModelPrefs (loadModelPrefs, saveModelPrefs, toggleFavorite)
import UI.Render.Sidebar (agentTreeLines)
import System.Directory (getCurrentDirectory)
import UI.Commands.Plan (approvePlanStep, decidePlanStep, runPlan)
import UI.Commands.Tools (gitCount, jsonMaybeStr, jsonStr, readProviderKey, runLocalShell, runTools)
import UI.Commands.Session (friendlyDenyError, resumeMessages, resumeSessions, runSession)
import Config.Settings (resolveConfig, saveConfig)
```

恢复：`git show 4185dda 58e0566 db89e3c -- "packages/app/CLI/UI/Commands.hs" | grep "^+import"`

### `packages/app/CLI/UI/Commands/Config.hs`

```haskell
import Data.Char (isHexDigit)
import UI.ProviderPresets (presets, preBaseUrl, preKind, preName)
import Core.Export (exportMarkdown, exportJson, defaultExportName)
import Core.Memory (allMemories, forgetText, rememberText)
import Core.Transcript (listLocalSessions, listLocalSessionsIn, loadTranscript, recordChunk, recordModelRequest, recordSession, recordToolEvent, recordUser)
import Control.Concurrent (threadDelay)
import Control.Exception (IOException, catch, try)
import Data.List (partition, sort)
import System.IO (hClose, hFlush, hPutStr, openTempFile, stdout)
import System.Environment (lookupEnv, getEnvironment)
import Core.Clipboard (saveClipboardImage)
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist, getHomeDirectory, getTemporaryDirectory, listDirectory, removeFile)
import System.Process (readProcessWithExitCode, readCreateProcessWithExitCode, proc, env)
import Data.Time.LocalTime (getCurrentTimeZone, utcToZonedTime)
import System.Directory (createDirectoryIfMissing, getHomeDirectory)
import Text.Read (readMaybe)
import System.Process (callCommand)
import UI.ModelPrefs (loadModelPrefs, saveModelPrefs, toggleFavorite)
import UI.Render.Sidebar (agentTreeLines)
import System.Directory (getCurrentDirectory)
```

恢复：`git show 4185dda 58e0566 db89e3c -- "packages/app/CLI/UI/Commands/Config.hs" | grep "^+import"`

### `packages/app/CLI/UI/Commands/Helpers.hs`

```haskell
import UI.ProviderPresets (presets, preBaseUrl, preKind, preName)
import Core.Export (exportMarkdown, exportJson, defaultExportName)
import Core.Memory (allMemories, forgetText, rememberText)
import Core.Transcript (listLocalSessions, listLocalSessionsIn, loadTranscript, recordChunk, recordModelRequest, recordSession, recordToolEvent, recordUser)
import Control.Concurrent (threadDelay)
import Control.Exception (IOException, catch, try)
import Data.List (partition, sort)
import System.IO (hClose, hFlush, hPutStr, openTempFile, stdout)
import System.Environment (lookupEnv, getEnvironment)
import Data.Maybe (fromMaybe)
import Core.Clipboard (saveClipboardImage)
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist, getHomeDirectory, getTemporaryDirectory, listDirectory, removeFile)
import System.Process (readProcessWithExitCode, readCreateProcessWithExitCode, proc, env)
import System.Timeout (timeout)
import Data.Time.Clock (getCurrentTime)
import Data.Time.LocalTime (getCurrentTimeZone, utcToZonedTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import System.Directory (createDirectoryIfMissing, getHomeDirectory)
import System.Process (callCommand)
import UI.ModelPrefs (loadModelPrefs, saveModelPrefs, toggleFavorite)
import UI.Render.Sidebar (agentTreeLines)
import System.Directory (getCurrentDirectory)
import Config.Settings (resolveConfig, saveConfig)
```

恢复：`git show 4185dda 58e0566 db89e3c -- "packages/app/CLI/UI/Commands/Helpers.hs" | grep "^+import"`

### `packages/app/CLI/UI/Commands/Integration.hs`

```haskell
import Data.Char (isHexDigit)
import UI.ProviderPresets (presets, preBaseUrl, preKind, preName)
import Core.Export (exportMarkdown, exportJson, defaultExportName)
import Core.Transcript (listLocalSessions, listLocalSessionsIn, loadTranscript, recordChunk, recordModelRequest, recordSession, recordToolEvent, recordUser)
import Control.Concurrent (threadDelay)
import Control.Exception (IOException, catch, try)
import Data.List (partition, sort)
import System.IO (hClose, hFlush, hPutStr, openTempFile, stdout)
import System.Environment (lookupEnv, getEnvironment)
import Core.Clipboard (saveClipboardImage)
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist, getHomeDirectory, getTemporaryDirectory, listDirectory, removeFile)
import System.Process (readProcessWithExitCode, readCreateProcessWithExitCode, proc, env)
import System.Timeout (timeout)
import Data.Time.Clock (getCurrentTime)
import Data.Time.LocalTime (getCurrentTimeZone, utcToZonedTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import System.Directory (createDirectoryIfMissing, getHomeDirectory)
import System.Environment (lookupEnv)
import Text.Read (readMaybe)
import System.Process (callCommand)
import UI.ModelPrefs (loadModelPrefs, saveModelPrefs, toggleFavorite)
import Config.Settings (resolveConfig, saveConfig)
```

恢复：`git show 4185dda 58e0566 db89e3c -- "packages/app/CLI/UI/Commands/Integration.hs" | grep "^+import"`

### `packages/app/CLI/UI/Commands/Meta.hs`

```haskell
import Bridge.Scheduler (fetchServiceStatus)
import UI.I18n (tr)
  (lspLines, mcpLines) <- fetchServiceStatus (ceBridge env)
```

恢复：`git show 4185dda 58e0566 db89e3c -- "packages/app/CLI/UI/Commands/Meta.hs" | grep "^+import"`

### `packages/app/CLI/UI/Commands/Model.hs`

```haskell
import Data.Char (isHexDigit)
import Core.Export (exportMarkdown, exportJson, defaultExportName)
import Core.Memory (allMemories, forgetText, rememberText)
import Core.Transcript (listLocalSessions, listLocalSessionsIn, loadTranscript, recordChunk, recordModelRequest, recordSession, recordToolEvent, recordUser)
import Control.Concurrent (threadDelay)
import Control.Exception (IOException, catch, try)
import Data.List (partition, sort)
import System.IO (hClose, hFlush, hPutStr, openTempFile, stdout)
import System.Environment (lookupEnv, getEnvironment)
import Data.Maybe (fromMaybe)
import Core.Clipboard (saveClipboardImage)
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist, getHomeDirectory, getTemporaryDirectory, listDirectory, removeFile)
import System.Process (readProcessWithExitCode, readCreateProcessWithExitCode, proc, env)
import System.Timeout (timeout)
import Data.Time.Clock (getCurrentTime)
import Data.Time.LocalTime (getCurrentTimeZone, utcToZonedTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import System.Directory (createDirectoryIfMissing, getHomeDirectory)
import System.Environment (lookupEnv)
import Text.Read (readMaybe)
import System.Process (callCommand)
import UI.Render.Sidebar (agentTreeLines)
import System.Directory (getCurrentDirectory)
```

恢复：`git show 4185dda 58e0566 db89e3c -- "packages/app/CLI/UI/Commands/Model.hs" | grep "^+import"`

### `packages/app/CLI/UI/Commands/Plan.hs`

```haskell
import Data.Char (isHexDigit)
import UI.ProviderPresets (presets, preBaseUrl, preKind, preName)
import Core.Export (exportMarkdown, exportJson, defaultExportName)
import Core.Memory (allMemories, forgetText, rememberText)
import Core.Transcript (listLocalSessions, listLocalSessionsIn, loadTranscript, recordChunk, recordModelRequest, recordSession, recordToolEvent, recordUser)
import Data.List (partition, sort)
import System.IO (hClose, hFlush, hPutStr, openTempFile, stdout)
import System.Environment (lookupEnv, getEnvironment)
import Core.Clipboard (saveClipboardImage)
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist, getHomeDirectory, getTemporaryDirectory, listDirectory, removeFile)
import System.Process (readProcessWithExitCode, readCreateProcessWithExitCode, proc, env)
import System.Timeout (timeout)
import Data.Time.LocalTime (getCurrentTimeZone, utcToZonedTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import System.Directory (createDirectoryIfMissing, getHomeDirectory)
import System.Process (callCommand)
import UI.ModelPrefs (loadModelPrefs, saveModelPrefs, toggleFavorite)
import UI.Render.Sidebar (agentTreeLines)
import Config.Settings (resolveConfig, saveConfig)
```

恢复：`git show 4185dda 58e0566 db89e3c -- "packages/app/CLI/UI/Commands/Plan.hs" | grep "^+import"`

### `packages/app/CLI/UI/Commands/Registry.hs`

```haskell
import Data.List (minimumBy, sortOn)
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Ord (comparing)
import UI.Commands.Registry.Parser (parseCommand, parseCommandBase, parseCommandWith)
```

恢复：`git show 4185dda 58e0566 db89e3c -- "packages/app/CLI/UI/Commands/Registry.hs" | grep "^+import"`

### `packages/app/CLI/UI/Commands/Registry/Settings.hs`

```haskell
import Data.List (minimumBy, sortOn)
import Data.Maybe (fromMaybe, listToMaybe)
```

恢复：`git show 4185dda 58e0566 db89e3c -- "packages/app/CLI/UI/Commands/Registry/Settings.hs" | grep "^+import"`

### `packages/app/CLI/UI/Commands/Session.hs`

```haskell
import Data.Char (isHexDigit)
import UI.ProviderPresets (presets, preBaseUrl, preKind, preName)
import Core.Memory (allMemories, forgetText, rememberText)
import Core.Transcript (listLocalSessions, listLocalSessionsIn, loadTranscript, recordChunk, recordModelRequest, recordSession, recordToolEvent, recordUser)
import Control.Concurrent (threadDelay)
import Data.List (partition, sort)
import System.IO (hClose, hFlush, hPutStr, openTempFile, stdout)
import System.Environment (lookupEnv, getEnvironment)
import Core.Clipboard (saveClipboardImage)
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist, getHomeDirectory, getTemporaryDirectory, listDirectory, removeFile)
import System.Process (readProcessWithExitCode, readCreateProcessWithExitCode, proc, env)
import System.Timeout (timeout)
import System.Environment (lookupEnv)
import Text.Read (readMaybe)
import UI.ModelPrefs (loadModelPrefs, saveModelPrefs, toggleFavorite)
import UI.Render.Sidebar (agentTreeLines)
import Config.Settings (resolveConfig, saveConfig)
```

恢复：`git show 4185dda 58e0566 db89e3c -- "packages/app/CLI/UI/Commands/Session.hs" | grep "^+import"`

### `packages/app/CLI/UI/Commands/Tools.hs`

```haskell
import Data.Char (isHexDigit)
import UI.ProviderPresets (presets, preBaseUrl, preKind, preName)
import Core.Export (exportMarkdown, exportJson, defaultExportName)
import Core.Memory (allMemories, forgetText, rememberText)
import Core.Transcript (listLocalSessions, listLocalSessionsIn, loadTranscript, recordChunk, recordModelRequest, recordSession, recordToolEvent, recordUser)
import Control.Concurrent (threadDelay)
import Control.Exception (IOException, catch, try)
import Data.List (partition, sort)
import System.IO (hClose, hFlush, hPutStr, openTempFile, stdout)
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist, getHomeDirectory, getTemporaryDirectory, listDirectory, removeFile)
import Data.Time.Clock (getCurrentTime)
import Data.Time.LocalTime (getCurrentTimeZone, utcToZonedTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import System.Directory (createDirectoryIfMissing, getHomeDirectory)
import Text.Read (readMaybe)
import System.Process (callCommand)
import UI.ModelPrefs (loadModelPrefs, saveModelPrefs, toggleFavorite)
import UI.Render.Sidebar (agentTreeLines)
import System.Directory (getCurrentDirectory)
import Config.Settings (resolveConfig, saveConfig)
```

恢复：`git show 4185dda 58e0566 db89e3c -- "packages/app/CLI/UI/Commands/Tools.hs" | grep "^+import"`

### `packages/app/CLI/UI/Main.hs`

```haskell
import Data.Text (Text)
```

恢复：`git show 4185dda 58e0566 db89e3c -- "packages/app/CLI/UI/Main.hs" | grep "^+import"`

### `packages/app/CLI/UI/Render/Settings.hs`

```haskell
import Data.Text (Text)
```

恢复：`git show 4185dda 58e0566 db89e3c -- "packages/app/CLI/UI/Render/Settings.hs" | grep "^+import"`

### `packages/app/CLI/UI/Session.hs`

```haskell
import Data.Text (Text)
```

恢复：`git show 4185dda 58e0566 db89e3c -- "packages/app/CLI/UI/Session.hs" | grep "^+import"`

### `packages/app/CLI/UI/Stash.hs`

```haskell
import Control.Monad (when)
```

恢复：`git show 4185dda 58e0566 db89e3c -- "packages/app/CLI/UI/Stash.hs" | grep "^+import"`

## 保留策略

import 里凡含 `(` 的符号（`Foo(..)`、`Foo(Bar, Baz)`）一律**整行保留**：
正文往往只出现构造子（`FoldCollapsed`、`ReasoningDelta`），类型名 `Foo` 从不出现，
按「类型名未出现」删行会立刻触发 `Data constructor not in scope`。

首版脚本正是这样误删的，回滚后改为整行保留，剩余 1384 个符号即因此保留。
