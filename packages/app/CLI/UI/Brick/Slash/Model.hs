{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | 模型与供应商类斜杠命令：@/models@、@/provider@、@/switch@。
--
-- 从 "UI.Brick.Slash" 拆出（认领式分派）。
module UI.Brick.Slash.Model
  ( handleModelSlash
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

handleModelSlash :: CmdCtx -> Maybe (EventM ResourceName AppState ())
handleModelSlash cx = case cxCmd cx of
    "/models" -> Just $ do
      st2 <- get
      case appProvider st2 >>= \n -> find ((== n) . piName) (appProviders st2) of
        Just p | not (null (piModels p)) ->
          -- The picker is scoped to the selected provider; no round trip.
          modify $ \s -> s { appDialogs =
            stackPush (DialogModels (orderedModels (appModelPrefs s) (providerModelInfos p)) "" 0)
                      (appDialogs s) }
        _ -> do
          modify $ \s -> s { appDialogs = stackPush (DialogModels [] "" 0) (appDialogs s) }
          void $ liftIO $ async $
            listModels (cxBridge cx) >>= writeBChan (cxChan cx) . EvModels
    "/provider" -> Just $ do
      modify $ \s -> s { appDialogs = stackPush (DialogProviders [] 0) (appDialogs s) }
      void $ liftIO $ async $
        listProviders (cxBridge cx) >>= writeBChan (cxChan cx) . EvProviders
    -- /switch 之前没有 TUI 分支，落到 executeCommand 的 SwitchProvider
    -- 分支只打印一段带 `*` 的列表 —— 用户看到「列出来但选不中」。
    -- 无参时和 /provider 走同一个可选中对话框；带参就直接切。
    _ | (cxCmd cx) == "/switch" || "/switch " `T.isPrefixOf` (cxCmd cx) -> Just $ do
      let arg = T.strip (T.drop (T.length "/switch") (cxInput cx))
      if T.null arg
        then do
          modify $ \s -> s { appDialogs = stackPush (DialogProviders [] 0) (appDialogs s) }
          void $ liftIO $ async $
            listProviders (cxBridge cx) >>= writeBChan (cxChan cx) . EvProviders
        else do
          r <- liftIO $ setInUseProvider (cxBridge cx) arg
          case r of
            Right _ -> showToast (tr (cxLang cx) "Switched to " <> arg)
            Left e  -> appendMsg (mkMsg "error" (T.pack (show e)) (cxTime cx))
    _ | (cxCmd cx) == "/ctx" || "/ctx " `T.isPrefixOf` (cxCmd cx) -> Just $ do
      cfg <- liftIO (resolveConfig defaultCLIConfig)
      let raw = T.strip (T.drop (T.length "/ctx") (cxCmd cx))
      if T.null raw
        then appendMsg (mkMsg "system" ("context: "
                          <> maybe "model default" (T.pack . show) (configCtxSize cfg)) (cxTime cx))
        else case reads (T.unpack raw) :: [(Int, String)] of
          [(n, "")] | n > 0 -> do
            liftIO (saveConfig (cfg { configCtxSize = Just n }))
            modify $ \s -> s { appCtxSize = Just n }
            -- Keep the saved provider's window in sync, so the kernel's
            -- compaction threshold and the UI agree after a restart.
            providers <- liftIO (listProviders (cxBridge cx))
            case providers of
              Right ps | (p : _) <- [ q | q <- ps, piInUse q ] -> do
                void $ liftIO $ async $ do
                  saved <- saveProvider (cxBridge cx) (piName p) (piKind p) (piBaseUrl p) ""
                             (piModels p) (piDefault p) (piAuthHeader p) (piNoProxy p)
                             (piEffort p) (piVision p) (piEfforts p)
                             (piHeaders p) (piExtraBody p) (piThinking p) (piResponsesMode p)
                             (Just n)
                  writeBChan (cxChan cx) (EvProviderSaved saved)
              _ -> pure ()
            appendMsg (mkMsg "system" ("context: " <> T.pack (show n) <> " tokens") (cxTime cx))
          _ -> appendMsg (mkMsg "error" "Usage: /ctx <tokens>" (cxTime cx))
    _ | (cxCmd cx) == "/effort" || "/effort " `T.isPrefixOf` (cxCmd cx) -> Just $ do
      cfg <- liftIO (resolveConfig defaultCLIConfig)
      -- Reasonix shape: the endpoint/model advertises an effort ladder
      -- (probe.efforts); validate against it instead of a hard-coded list.
      providers <- liftIO (listProviders (cxBridge cx))
      let (base, kind, ladder) = case providers of
            Right ps -> case [ p | p <- ps, piInUse p ] of
              (p : _) -> (piBaseUrl p, piKind p, piEfforts p)
              []      -> maybe ("", "", [])
                              (\p -> (piBaseUrl p, piKind p, piEfforts p))
                              (listToMaybe ps)
            Left _ -> ("", "", [])
          levels = levelsFor ladder base kind (appModel (cxState cx))
          lvl = T.toLower (T.strip (T.drop (T.length "/effort") (cxCmd cx)))
          shown = "(" <> T.intercalate "|" levels <> ")"
      if T.null lvl
        then appendMsg (mkMsg "system" ("effort: " <> configEffort cfg <> "  " <> shown) (cxTime cx))
        else if lvl `elem` levels
          then do
            liftIO (saveConfig (cfg { configEffort = lvl }))
            modify $ \s -> s { appEffort = lvl }
            appendMsg (mkMsg "system" ("effort: " <> lvl) (cxTime cx))
          else appendMsg (mkMsg "error" ("Unknown effort: " <> lvl <> "  " <> shown) (cxTime cx))
    _ | (cxCmd cx) == "/fav" || "/fav " `T.isPrefixOf` (cxCmd cx) -> Just $ do
      st2 <- get
      let arg = T.strip (T.drop 4 (cxInput cx))
          name = if T.null arg then appModel st2 else arg
          prefs' = toggleFavorite name (appModelPrefs st2)
      liftIO (saveModelPrefs prefs')
      modify $ \s -> s { appModelPrefs = prefs' }
      showToast (tr (cxLang cx) "Favourite: " <> name)
    _ | (cxCmd cx) == "/model" -> Just $
          appendMsg (mkMsg "system" ("Current model: " <> modelLabel (cxState cx)) (cxTime cx))

    _ | "/model " `T.isPrefixOf` (cxCmd cx) -> Just $ do
          let model = T.strip (T.drop 7 (cxInput cx))
          modify $ \s -> s { appModel = model }
          st2 <- get
          persistSelection (fromMaybe "" (appProvider st2)) model
          let prefs' = recordRecent model (appModelPrefs st2)
          liftIO (saveModelPrefs prefs')
          modify $ \s -> s { appModelPrefs = prefs' }
          appendMsg (mkMsg "system" ("Model set: " <> modelLabel (st2 { appModel = model })) (cxTime cx))
    _ -> Nothing
