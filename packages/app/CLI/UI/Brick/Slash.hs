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
import Data.Foldable (msum)
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
  , scrollBottom, withCommands )
import UI.Brick.Apply
  ( applyLanguage, applyTheme, modeAction, openSettingsPanel )
import UI.Brick.Toast (showToast)
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
    "/resume" -> do
      cwd <- liftIO getCurrentDirectory
      local <- liftIO (listLocalSessionsIn cwd)
      if null local
        then do
          appendMsg (mkMsg "system" (tr lang "No local sessions in this directory yet.") t)
          appendMsg (mkMsg "system" (tr lang "/resume --all shows sessions from other (or older) projects.") t)
        else do
          appendMsg (mkMsg "system" ("Local sessions:\n" <> T.unlines (localSessionLines (appLang st) local)) t)
          appendMsg (mkMsg "system" (tr lang "Resume with /resume <number-or-id>  (/resume --all for every project).") t)
    _ 
      | "/resume " `T.isPrefixOf` cmd -> resumeSession (T.strip (T.drop 8 input))
      | cmd == "/plan" ->
          appendMsg (mkMsg "system" (tr lang "Usage: /plan <what to do>") t)
      | "/plan " `T.isPrefixOf` cmd -> do
          let planText = T.strip (T.drop 6 input)
              steps = splitPlanSteps planText
          cur <- gets appSessionId
          case cur of
            Nothing ->
              appendMsg (mkMsg "system" "No session yet — use /new or send a message first." t)
            -- Two or more steps → a real multi-step plan, approved one step at a
            -- time. A single line keeps the single-command gate.
            Just sid | length steps >= 2 -> do
              appendMsg (mkMsg "user" planText t)
              modify $ \s2 -> s2 { appBusy = True, appStatus = "Planning..." }
              void $ liftIO $ async $ do
                recordUser sid planText
                r <- submitPlan bridge sid steps
                writeBChan chan (EvPlanState (fmap ((, Nothing)) r))
            Just sid -> do
              appendMsg (mkMsg "user" planText t)
              modify $ \s2 -> s2 { appBusy = True, appStatus = "Awaiting approval..." }
              void $ liftIO $ async $ do
                recordUser sid planText
                r <- planStep bridge sid planText
                writeBChan chan (EvPlan r)
      | cmd == "/model" ->
          appendMsg (mkMsg "system" ("Current model: " <> modelLabel st) t)
      | "/model " `T.isPrefixOf` cmd -> do
          let model = T.strip (T.drop 7 input)
          modify $ \s -> s { appModel = model }
          st2 <- get
          persistSelection (fromMaybe "" (appProvider st2)) model
          let prefs' = recordRecent model (appModelPrefs st2)
          liftIO (saveModelPrefs prefs')
          modify $ \s -> s { appModelPrefs = prefs' }
          appendMsg (mkMsg "system" ("Model set: " <> modelLabel (st2 { appModel = model })) t)
      | "/delete " `T.isPrefixOf` cmd -> do
          let sid = T.unpack (T.strip (T.drop 8 input))
          if null sid
            then appendMsg (mkMsg "system" "Usage: /delete <session-id>" t)
            else do
              cur <- gets appSessionId
              when (cur == Just sid) $
                modify $ \s -> s { appSessionId = Nothing
                                 , appCacheNow = Nothing
                                 , appCacheSum = (0, 0)
                                 , appCacheTurns = 0
                                 , appLastCost = 0
                                 , appSessTokens = 0
                                 , appLastDecodeTps = Nothing
                                 , appFirstToken = Nothing }
              void $ liftIO $ async $ do
                _ <- deleteSession bridge sid
                writeBChan chan (EvDeleted sid)
      | cmd `elem` ["/skip", "/reject", "/abandon"] -> do
          cur <- gets appSessionId
          case cur of
            Nothing ->
              appendMsg (mkMsg "system" "No session yet — use /new or send a message first." t)
            Just sid -> do
              -- 没有待审批计划时先说清楚，不要拿一条内核 502 当反馈。
              plan <- liftIO (fetchPlan bridge sid)
              case plan of
                Right pv | pvPhase pv == "planning" -> do
                  let action = T.drop 1 cmd
                  modify $ \s2 -> s2 { appBusy = True, appStatus = "Plan decision..." }
                  void $ liftIO $ async $ do
                    r <- decideStep bridge sid action
                    writeBChan chan (EvPlanState (fmap ((, Nothing)) r))
                _ -> appendMsg (mkMsg "system"
                       (tr lang "No pending plan — submit one with /plan first.") t)
      | otherwise -> case parseCommandWith (map ccName (appCustomCmds st)) input of
          Unknown _ ->
            appendMsg (mkMsg "system" (tr lang "Unknown command: " <> input <> tr lang " — try /help") t)
          RunCustom name args ->
            case [ cc | cc <- appCustomCmds st, ccName cc == name ] of
              (cc : _) -> handleChatWith input (renderCustomCommand cc args)
              [] -> appendMsg (mkMsg "system"
                      (tr lang "Unknown command: " <> input <> tr lang " — try /help") t)
          StopRequest ->
            appendMsg (mkMsg "system"
              (tr lang "This stops the kernel and scheduler and exits TUI. Type /stop confirm to proceed.") t)
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

