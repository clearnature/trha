{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | 会话类斜杠命令：@/new@、@/clear@、@/sessions@、@/rename@、@/tag@。
--
-- 从 "UI.Brick.Slash" 拆出（认领式分派）。
module UI.Brick.Slash.Session
  ( handleSessionSlash
  ) where

import Brick
import Brick.BChan
import Brick.Widgets.Border
import Brick.Widgets.Edit
import Control.Concurrent.Async (async)
import Control.Monad (void, when)
import Control.Monad.IO.Class (liftIO)
import Core.Types
import Bridge.Scheduler (SchedulerBridge, listPlugins, subscribeSessionEvents, subscribeSessionEventsWithTerminal, listSessions, createSession, deleteSession, sendMessage, sendMessageWithTarget, sendMessageWithTargetEffort, allowAlways, interruptSession, fetchSessionInfo, fetchAgents, SessionInfo(..), listProviders, saveProvider, probeProvider, removeProvider, ProviderProbe(..), listModels, planStep, approvePlan, denyPlan, submitPlan, decideStep, decidePlan, reportStep, fetchSessionMode, applySessionMode, renameSession, tagSession, fetchServiceStatus, denyPlanWithReason, fetchBalance, transcribeVoice, setSandboxConfig, fetchSandboxConfig, setSessionCwd, fetchPlan, setInUseProvider)
import Core.Replay (ReplayBlock(..), renderReplay)
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
import Core.Transcript (listLocalSessionsIn, loadTranscript)
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
import Data.Time.Clock (getCurrentTime)
import Data.Time.LocalTime (getCurrentTimeZone, utcToZonedTime)
import Data.Time.Format (formatTime, defaultTimeLocale)
import Graphics.Vty.Attributes
import Graphics.Vty.Input.Events
import qualified Graphics.Vty as V
import Lens.Micro ((&), (.~), (%~), (^.))
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
import System.Directory (getCurrentDirectory, createDirectoryIfMissing, getHomeDirectory)
import System.FilePath ((</>), takeDirectory, takeFileName)
import System.Exit (ExitCode(..))
import Control.Exception (IOException, try)
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

handleSessionSlash :: CmdCtx -> Maybe (EventM ResourceName AppState ())
handleSessionSlash cx = case cxCmd cx of
  "/clear" -> Just $ slashClear cx
  "/new" -> Just $ slashNew cx
  "/sessions" -> Just $ slashSessions cx
  "/rename" -> Just $ slashRename cx
  "/tag" -> Just $ slashTag cx
  _ | (cxCmd cx) == "/delete" || "/delete " `T.isPrefixOf` (cxCmd cx) -> Just $ slashDeleteConfirm cx
  "/export" -> Just $ slashExport cx
  _ | "/resume " `T.isPrefixOf` (cxCmd cx) -> Just $ slashResumeSession cx
  _ | "/delete " `T.isPrefixOf` (cxCmd cx) -> Just $ slashDeleteSession cx
  "/resume" -> Just $ slashResumeList cx
  _ -> Nothing

-- | @?@
slashClear :: CmdCtx -> EventM ResourceName AppState ()
slashClear cx = do
  modify $ \s -> s { appMessages = [], appFolds = Map.empty, appCardFocus = Nothing }
  showToast (tr (cxLang cx) "Cleared")

-- | @?@
slashNew :: CmdCtx -> EventM ResourceName AppState ()
slashNew cx = do
  st0 <- get
  -- 把当前姿态带进新会话：Shift+Tab/Ctrl+Y 选的是「待用姿态」，
  -- 只有落到 createSession 才算真的切换（否则服务端仍是 read-only）。
  let pm = smMode <$> appMode st0
  modify $ \s -> s { appBusy = True, appStatus = "Creating session..." }
  void $ liftIO $ async $
    createSession (cxBridge cx) pm >>= writeBChan (cxChan cx) . EvSession

-- | @?@
slashSessions :: CmdCtx -> EventM ResourceName AppState ()
slashSessions cx = do
  cwd <- liftIO getCurrentDirectory
  local <- liftIO (listLocalSessionsIn cwd)
  if null local
    then appendMsg (mkMsg "system" (tr (cxLang cx) "No local sessions in this directory yet. Run a conversation first.") (cxTime cx))
    else modify $ \s -> s { appDialogs = stackPush (DialogSessions local "" 0) (appDialogs s) }

-- | @?@
slashRename :: CmdCtx -> EventM ResourceName AppState ()
slashRename cx = do
  st2 <- get
  let title = T.strip (T.drop 7 (cxInput cx))
  case appSessionId st2 of
    Nothing -> appendMsg (mkMsg "system" (tr (cxLang cx) "No active session.") (cxTime cx))
    Just sid -> do
      r <- liftIO $ renameSession (appBridge st2) sid title
      case r of
        Right _ -> showToast (tr (cxLang cx) "Renamed")
        Left e  -> appendMsg (mkMsg "error" (T.pack (show e)) (cxTime cx))

-- | @?@
slashTag :: CmdCtx -> EventM ResourceName AppState ()
slashTag cx = do
  st2 <- get
  let tags = T.words (T.drop 4 (cxInput cx))
  case appSessionId st2 of
    Nothing -> appendMsg (mkMsg "system" (tr (cxLang cx) "No active session.") (cxTime cx))
    Just sid -> do
      r <- liftIO $ tagSession (appBridge st2) sid tags
      case r of
        Right _ -> showToast (tr (cxLang cx) "Tags updated")
        Left e  -> appendMsg (mkMsg "error" (T.pack (show e)) (cxTime cx))

-- | @?@
slashDeleteConfirm :: CmdCtx -> EventM ResourceName AppState ()
slashDeleteConfirm cx = do
  let sid = T.strip (T.drop (T.length "/delete") (cxInput cx))
  if T.null sid
    then appendMsg (mkMsg "error" (tr (appLang (cxState cx)) "Usage: /delete <session-id>") (cxTime cx))
    else modify $ \s -> s
           { appDialogs = stackPush (DialogConfirm ("Delete session " <> sid <> "?") 1) (appDialogs s)
           , appPendingDelete = Just (T.unpack sid) }

-- | @?@
slashExport :: CmdCtx -> EventM ResourceName AppState ()
slashExport cx = do
  st2 <- get
  case appSessionId st2 of
    Nothing -> appendMsg (mkMsg "system" (tr (cxLang cx) "No session to export") (cxTime cx))
    Just sid -> do
      evs <- liftIO (loadTranscript sid)
      (dir, stamp) <- liftIO $ do
        nowT <- getCurrentTime
        tz <- getCurrentTimeZone
        home <- getHomeDirectory
        pure (home </> ".trha" </> "exports",
              T.pack (formatTime defaultTimeLocale "%Y%m%d-%H%M%S" (utcToZonedTime tz nowT)))
      let args = T.words (T.drop 7 (cxInput cx))
          asJson = case args of
            (a : _) -> T.toLower a == "json"
            []      -> False
          explicit = case args of
            (a : b : _) | T.toLower a `elem` ["json", "md", "markdown"] -> Just b
            (a : _) | T.toLower a `notElem` ["json", "md", "markdown"] -> Just a
            _ -> Nothing
          ext = if asJson then "json" else "md"
          path = case explicit of
            Just p
              | "/" `T.isPrefixOf` p -> T.unpack p
              | otherwise            -> dir </> T.unpack p
            Nothing -> dir </> defaultExportName (T.pack sid) stamp ext
          body = if asJson then exportJson (T.pack sid) stamp evs
                           else exportMarkdown (T.pack sid) stamp evs
      written <- liftIO (try (do
        createDirectoryIfMissing True (takeDirectory path)
        TIO.writeFile path body) :: IO (Either IOException ()))
      case written of
        Right () -> do
          appendMsg (mkMsg "system" ("exported → " <> T.pack path) (cxTime cx))
          showToast ("exported → " <> T.pack path)
        Left e   -> appendMsg (mkMsg "error" ("export failed: " <> T.pack (show e)) (cxTime cx))

-- | @?@
slashResumeSession :: CmdCtx -> EventM ResourceName AppState ()
slashResumeSession cx = resumeSession (T.strip (T.drop 8 (cxInput cx)))

-- | @?@
slashDeleteSession :: CmdCtx -> EventM ResourceName AppState ()
slashDeleteSession cx = do
      let sid = T.unpack (T.strip (T.drop 8 (cxInput cx)))
      if null sid
        then appendMsg (mkMsg "system" "Usage: /delete <session-id>" (cxTime cx))
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
            _ <- deleteSession (cxBridge cx) sid
            writeBChan (cxChan cx) (EvDeleted sid)

-- | @?@
slashResumeList :: CmdCtx -> EventM ResourceName AppState ()
slashResumeList cx = do
  cwd <- liftIO getCurrentDirectory
  local <- liftIO (listLocalSessionsIn cwd)
  if null local
    then do
      appendMsg (mkMsg "system" (tr (cxLang cx) "No local sessions in this directory yet.") (cxTime cx))
      appendMsg (mkMsg "system" (tr (cxLang cx) "/resume --all shows sessions from other (or older) projects.") (cxTime cx))
    else do
      appendMsg (mkMsg "system" ("Local sessions:\n" <> T.unlines (localSessionLines (appLang (cxState cx)) local)) (cxTime cx))
      appendMsg (mkMsg "system" (tr (cxLang cx) "Resume with /resume <number-or-id>  (/resume --all for every project).") (cxTime cx))
