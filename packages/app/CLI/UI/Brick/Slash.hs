{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | 斜杠命令的 TUI 分派（从 @UI.Brick@ 拆出，489 行）。
--
-- 41 个分支共享同一层 @t/st/cmd/bridge/chan/lang@ 绑定与末尾的 scrollBottom，
-- 所以它作为一个整体搬出，而不是按分支切割。
module UI.Brick.Slash
  ( handleSlash
  ) where

import Brick
import Brick.BChan
import Brick.Widgets.Border
import Brick.Widgets.Edit
import Control.Monad.IO.Class (liftIO)
import Core.Types
import Bridge.Scheduler (SchedulerBridge, listPlugins, subscribeSessionEvents, subscribeSessionEventsWithTerminal, listSessions, createSession, deleteSession, sendMessage, sendMessageWithTarget, sendMessageWithTargetEffort, allowAlways, interruptSession, fetchSessionInfo, fetchAgents, SessionInfo(..), listProviders, saveProvider, probeProvider, removeProvider, ProviderProbe(..), listModels, planStep, approvePlan, denyPlan, submitPlan, decideStep, decidePlan, reportStep, fetchSessionMode, applySessionMode, renameSession, tagSession, fetchServiceStatus, denyPlanWithReason, fetchBalance, transcribeVoice, setSandboxConfig, fetchSandboxConfig, setSessionCwd, fetchPlan, setInUseProvider)
import Core.Replay (ReplayBlock(..), renderReplay)
import Core.RunState (stopAll, stopResultText)
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
import UI.Commands (executeCommand)
import UI.Commands.Registry
    ( Command(..), parseCommandWith, pickerItems, pickerItemsGrouped
    , groupKey, groupTitle, helpTextFor, registryHelp )
import UI.SettingsView (SettingsEntry(..), settingsEntries, filterEntries, isOverridden, maskSecret)
import UI.State
import UI.StatusInfo (StatusRow(..), collectStatusInfo)
import UI.StatsView (StatsBlock(..), buildStatsBlocks)
import UI.I18n (Lang(..), langName, parseLang, tr)
import Data.IORef (newIORef, readIORef)
import qualified Data.Map.Strict as Map
import Data.Foldable (msum)
import Data.Text (Text)
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
import UI.Brick.Slash.Info (handleInfoSlash)
import UI.Brick.Slash.Lifecycle (handleLifecycleSlash)
import UI.Brick.Slash.Session (handleSessionSlash)
import UI.Brick.Slash.Config (handleConfigSlash)
import UI.Brick.Slash.Integration (handleIntegrationSlash)
import UI.Brick.Slash.Model (handleModelSlash)
import UI.Brick.Slash.Plan (handlePlanSlash)
import UI.Brick.Slash.Tools (handleToolsSlash)
import UI.Brick.Slash.Workspace (handleWorkspaceSlash)
import UI.Brick.Chat (handleChatWith)
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
import Control.Exception (try)
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

handleSlash :: Text -> EventM ResourceName AppState ()
handleSlash input = do
  t <- liftIO now
  st <- get
  -- Frecency: count the command word (arguments excluded).  Manual typing and
  -- palette selection both land here, so the ranking reflects real usage.
  let frecKey = "/" <> T.toLower (T.takeWhile (/= ' ') (T.drop 1 input))
      frec' = recordUse frecKey (appFrecency st)
  liftIO (saveFrecency frec')
  modify $ \s -> s { appFrecency = frec' }
  let cmd = T.toLower input
      bridge = appBridge st
      chan   = appChan st
      lang   = appLang st
      cx     = CmdCtx t st input cmd bridge chan lang
  case cmd of
    _ | Just act <- msum [ handleLifecycleSlash cx, handleInfoSlash cx, handleConfigSlash cx
         , handleIntegrationSlash cx, handleModelSlash cx, handlePlanSlash cx, handleSessionSlash cx, handleToolsSlash cx, handleWorkspaceSlash cx ] -> act
    _ 
      | otherwise -> case parseCommandWith (map ccName (appCustomCmds st)) input of
          Unknown _ ->
            appendMsg (mkMsg "system" (tr lang "Unknown command: " <> input <> tr lang " — try /help") t)
          RunCustom name args ->
            case [ cc | cc <- appCustomCmds st, ccName cc == name ] of
              (cc : _) -> handleChatWith input (renderCustomCommand cc args)
              [] -> appendMsg (mkMsg "system"
                      (tr lang "Unknown command: " <> input <> tr lang " — try /help") t)
          StopRequest ->
            -- 与 Ctrl+Alt+Q 同一确认对话框（requestStopServices / appPendingStop），
            -- 取代「请手敲 /stop confirm」的文本式确认。
            requestStopServices
          StopConfirmed -> do
            rs <- liftIO (stopAll False)
            let out = T.intercalate "\n"
                        [ T.pack (stopResultText svc r) | (svc, r) <- rs ]
            appendMsg (mkMsg "system" out t)
            halt
          c -> do
            -- Every registry command now reaches the same implementation the
            -- REPL uses; before this, new commands were "Unknown" in the TUI.
            ref <- liftIO (newIORef (appSessionId st))
            mref <- liftIO (newIORef (appModel st))
            r <- liftIO $ executeCommand lang bridge ref mref c
            sid' <- liftIO (readIORef ref)
            modify $ \s -> s { appSessionId = sid'
                             , appCacheNow = Nothing
                             , appCacheSum = (0, 0)
                             , appCacheTurns = 0 }
            case r of
              Just out | not (T.null (T.strip out)) -> appendMsg (mkMsg "system" out t)
              _ -> pure ()
  scrollBottom

-- | Refresh the sidebar's TODO list and title for a session.  Best effort:
-- a scheduler that does not expose @teamTasks@ yields an empty list, and a
-- missing local transcript yields no title.
-- | refreshSidebar 见 UI.Brick.SessionView。

-- | Send a chat message: create session lazily, send async, never block UI.
-- While the step runs, tool lifecycle events arrive over SSE; they are
-- recorded to the transcript and surfaced through 'EvTool'.

