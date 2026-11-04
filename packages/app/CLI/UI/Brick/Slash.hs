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
    _ | Just act <- msum [handleLifecycleSlash cx, handleInfoSlash cx, handleSessionSlash cx] -> act
    _ | cmd == "/delete" || "/delete " `T.isPrefixOf` cmd -> do
      let sid = T.strip (T.drop (T.length "/delete") input)
      if T.null sid
        then appendMsg (mkMsg "error" (tr (appLang st) "Usage: /delete <session-id>") t)
        else modify $ \s -> s
               { appDialogs = stackPush (DialogConfirm ("Delete session " <> sid <> "?") 1) (appDialogs s)
               , appPendingDelete = Just (T.unpack sid) }

    _ | cmd == "/shell" || "/shell " `T.isPrefixOf` cmd -> do
      let arg = T.strip (T.drop (T.length "/shell") input)
      if T.null arg
        then appendMsg (mkMsg "error" (tr (appLang st) "Usage: /shell <cmd>") t)
        else runShellCommand arg
    _ | cmd == "/language" || "/language " `T.isPrefixOf` cmd -> do
      cfg <- liftIO (resolveConfig defaultCLIConfig)
      let raw = T.strip (T.drop (T.length "/language") input)
          available = T.intercalate ", " (map langName ([minBound .. maxBound] :: [Lang]))
      if T.null raw
        then modify $ \s -> s { appDialogs =
               stackPush (DialogLanguages ([minBound .. maxBound] :: [Lang]) 0) (appDialogs s) }
        else do
          let l = parseLang raw
          liftIO (saveConfig (cfg { configLang = langName l }))
          modify $ \s -> s { appLang = l, appStatus = tr l "Language: " <> langName l }
          appendMsg (mkMsg "system"
            (tr l "Language: " <> langName l <> "\n" <> tr l "available: " <> available) t)

    _ | cmd == "/ctx" || "/ctx " `T.isPrefixOf` cmd -> do
      cfg <- liftIO (resolveConfig defaultCLIConfig)
      let raw = T.strip (T.drop (T.length "/ctx") cmd)
      if T.null raw
        then appendMsg (mkMsg "system" ("context: "
                          <> maybe "model default" (T.pack . show) (configCtxSize cfg)) t)
        else case reads (T.unpack raw) :: [(Int, String)] of
          [(n, "")] | n > 0 -> do
            liftIO (saveConfig (cfg { configCtxSize = Just n }))
            modify $ \s -> s { appCtxSize = Just n }
            -- Keep the saved provider's window in sync, so the kernel's
            -- compaction threshold and the UI agree after a restart.
            providers <- liftIO (listProviders bridge)
            case providers of
              Right ps | (p : _) <- [ q | q <- ps, piInUse q ] -> do
                void $ liftIO $ async $ do
                  saved <- saveProvider bridge (piName p) (piKind p) (piBaseUrl p) ""
                             (piModels p) (piDefault p) (piAuthHeader p) (piNoProxy p)
                             (piEffort p) (piVision p) (piEfforts p)
                             (piHeaders p) (piExtraBody p) (piThinking p) (piResponsesMode p)
                             (Just n)
                  writeBChan chan (EvProviderSaved saved)
              _ -> pure ()
            appendMsg (mkMsg "system" ("context: " <> T.pack (show n) <> " tokens") t)
          _ -> appendMsg (mkMsg "error" "Usage: /ctx <tokens>" t)
    _ | cmd == "/effort" || "/effort " `T.isPrefixOf` cmd -> do
      cfg <- liftIO (resolveConfig defaultCLIConfig)
      -- Reasonix shape: the endpoint/model advertises an effort ladder
      -- (probe.efforts); validate against it instead of a hard-coded list.
      providers <- liftIO (listProviders bridge)
      let (base, kind, ladder) = case providers of
            Right ps -> case [ p | p <- ps, piInUse p ] of
              (p : _) -> (piBaseUrl p, piKind p, piEfforts p)
              []      -> maybe ("", "", [])
                              (\p -> (piBaseUrl p, piKind p, piEfforts p))
                              (listToMaybe ps)
            Left _ -> ("", "", [])
          levels = levelsFor ladder base kind (appModel st)
          lvl = T.toLower (T.strip (T.drop (T.length "/effort") cmd))
          shown = "(" <> T.intercalate "|" levels <> ")"
      if T.null lvl
        then appendMsg (mkMsg "system" ("effort: " <> configEffort cfg <> "  " <> shown) t)
        else if lvl `elem` levels
          then do
            liftIO (saveConfig (cfg { configEffort = lvl }))
            modify $ \s -> s { appEffort = lvl }
            appendMsg (mkMsg "system" ("effort: " <> lvl) t)
          else appendMsg (mkMsg "error" ("Unknown effort: " <> lvl <> "  " <> shown) t)
    "/home" -> do
      cwd <- liftIO getCurrentDirectory
      local <- liftIO (listLocalSessionsIn cwd)
      modify $ \s -> s { appRoute = RouteHome, appRecent = local
                       , appStatus = tr (appLang s) "Home" }
    -- Human channel: move the session's workspace.  No tool reaches this
    -- endpoint, so an agent cannot widen its own sandbox root.
    "/workspace" -> do
      st2 <- get
      let arg = T.strip (T.drop (T.length "/workspace") input)
      case appSessionId st2 of
        Nothing -> appendMsg (mkMsg "system" (tr lang "No active session.") t)
        Just sid
          | T.null arg ->
              appendMsg (mkMsg "system"
                (tr lang "Usage: /workspace <absolute-path>  (shows the sandbox root)") t)
          | otherwise -> do
              r <- liftIO (setSessionCwd (appBridge st2) sid (T.unpack arg))
              case r of
                Left e -> appendMsg (mkMsg "error"
                            (tr lang "Error: " <> T.pack (show e)) t)
                Right p -> do
                  modify $ \s -> s { appCwd = Just (T.pack p) }
                  appendMsg (mkMsg "system" ("Workspace: " <> T.pack p) t)
    _ | cmd == "/fav" || "/fav " `T.isPrefixOf` cmd -> do
      st2 <- get
      let arg = T.strip (T.drop 4 input)
          name = if T.null arg then appModel st2 else arg
          prefs' = toggleFavorite name (appModelPrefs st2)
      liftIO (saveModelPrefs prefs')
      modify $ \s -> s { appModelPrefs = prefs' }
      showToast (tr lang "Favourite: " <> name)
    "/stash" -> do
      st2 <- get
      let rest = T.strip (T.drop 6 input)
          entries = stashEntries (appStash st2)
      case T.words rest of
        [] -> case T.strip (editorValue st2) of
          "" -> appendMsg (mkMsg "system"
                  (tr lang "stash: " <> T.pack (show (length entries)) <> tr lang " drafts") t)
          draft -> do
            let st' = stashPush draft (appStash st2)
            liftIO (saveStash st')
            modify $ \s -> s { appStash = st', appInput = editorText InputArea (Just 1) "" }
            showToast (tr lang "Draft stashed")
        ("pop" : _) -> case stashPop (appStash st2) of
          Nothing -> appendMsg (mkMsg "system" (tr lang "stash is empty") t)
          Just (draft, st') -> do
            liftIO (saveStash st')
            modify $ \s -> s { appStash = st', appInput = editorText InputArea (Just 1) draft }
            showToast (tr lang "Draft restored")
        ("list" : _) -> appendMsg (mkMsg "system" (stashListing lang entries) t)
        _ -> do
          let st' = stashPush rest (appStash st2)
          liftIO (saveStash st')
          modify $ \s -> s { appStash = st' }
          showToast (tr lang "Draft stashed")
    "/export" -> do
      st2 <- get
      case appSessionId st2 of
        Nothing -> appendMsg (mkMsg "system" (tr lang "No session to export") t)
        Just sid -> do
          evs <- liftIO (loadTranscript sid)
          (dir, stamp) <- liftIO $ do
            nowT <- getCurrentTime
            tz <- getCurrentTimeZone
            home <- getHomeDirectory
            pure (home </> ".trha" </> "exports",
                  T.pack (formatTime defaultTimeLocale "%Y%m%d-%H%M%S" (utcToZonedTime tz nowT)))
          let args = T.words (T.drop 7 input)
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
              appendMsg (mkMsg "system" ("exported → " <> T.pack path) t)
              showToast ("exported → " <> T.pack path)
            Left e   -> appendMsg (mkMsg "error" ("export failed: " <> T.pack (show e)) t)
    "/settings"
      | T.null (T.strip (T.drop 9 input)) -> openSettingsPanel
      | otherwise -> do
          let arg = T.strip (T.drop 9 input)
          msg <- liftIO (runSettingsCommand lang arg)
          forM_ msg $ \m -> appendMsg (mkMsg "system" m t)
          scrollBottom
    "/models" -> do
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
            listModels bridge >>= writeBChan chan . EvModels
    "/sandbox" -> modify $ \s -> s { appDialogs =
      stackPush (DialogSandbox (appSandbox s) 0) (appDialogs s) }
    "/theme" -> do
      let arg = T.strip (T.drop 6 input)
      if T.null arg
        then modify $ \s -> s { appDialogs =
               stackPush (DialogThemes themes 0) (appDialogs s) }
        else applyTheme arg
    _ | cmd == "/mode" || "/mode " `T.isPrefixOf` cmd -> do
      -- 带参数的 /mode 也必须走 modeAction：兜底的 executeCommand 只改
      -- scheduler 侧、不更新 appMode，状态栏会一直停在旧姿态。
      let arg = T.strip (T.drop 5 input)
      if T.null arg
        then modeAction (object ["action" .= ("cycle" :: Text)])
        else modeAction (object ["action" .= ("set" :: Text), "mode" .= arg])
    "/verbose" -> do
      v <- gets appVerbose
      modify $ \s -> s { appVerbose = not v }
      showToast (if v then tr lang "Verbose off" else tr lang "Verbose on")
    "/todo" -> do
      st2 <- get
      t2 <- liftIO now
      let items = appTodos st2
      appendMsg (mkMsg "system"
        (if null items then tr lang "No tasks"
         else T.unlines [ "  " <> todoGlyph (todoStatus i) <> " " <> todoSubject i | i <- items ]) t2)
    "/tree" -> do
      st2 <- get
      t2 <- liftIO now
      let as = appAgents st2
      appendMsg (mkMsg "system"
        (if null as then tr lang "no agents"
         else T.unlines (agentTreeLines (fmap T.pack (appSessionId st2)) as)) t2)
    "/agents" -> do
      st2 <- get
      if null (appAgents st2)
        then appendMsg (mkMsg "system" (tr lang "no agents") t)
        else modify $ \s -> s { appDialogs =
               stackPush (DialogAgents (appAgents st2) 0) (appDialogs s) }
    "/skills" -> do
      st2 <- get
      modify $ \s -> s { appDialogs =
        stackPush (DialogSkills (appSkills st2) "" 0) (appDialogs s) }
    "/provider" -> do
      modify $ \s -> s { appDialogs = stackPush (DialogProviders [] 0) (appDialogs s) }
      void $ liftIO $ async $
        listProviders bridge >>= writeBChan chan . EvProviders
    -- /switch 之前没有 TUI 分支，落到 executeCommand 的 SwitchProvider
    -- 分支只打印一段带 `*` 的列表 —— 用户看到「列出来但选不中」。
    -- 无参时和 /provider 走同一个可选中对话框；带参就直接切。
    _ | cmd == "/switch" || "/switch " `T.isPrefixOf` cmd -> do
      let arg = T.strip (T.drop (T.length "/switch") input)
      if T.null arg
        then do
          modify $ \s -> s { appDialogs = stackPush (DialogProviders [] 0) (appDialogs s) }
          void $ liftIO $ async $
            listProviders bridge >>= writeBChan chan . EvProviders
        else do
          r <- liftIO $ setInUseProvider bridge arg
          case r of
            Right _ -> showToast (tr lang "Switched to " <> arg)
            Left e  -> appendMsg (mkMsg "error" (T.pack (show e)) t)
    "/approve" -> do
      cur <- gets appSessionId
      plan <- gets appPlan
      case cur of
        Nothing -> appendMsg (mkMsg "system" "No session yet — use /new or send a message first." t)
        Just sid -> case plan of
          Just pv | pvPhase pv == "planning" -> do
            -- multi-step plan: release the pending step, run it, report back
            modify $ \s -> s { appBusy = True, appStatus = "Approving step..." }
            void $ liftIO $ async $
              writeBChan chan . EvPlanState =<< approveAndRun bridge sid
          _ -> do
            modify $ \s -> s { appBusy = True, appStatus = "Executing plan..." }
            void $ liftIO $ async $ do
              r <- approvePlan bridge sid
              writeBChan chan (EvVerdict r)
    "/deny" -> do
      cur <- gets appSessionId
      let reason = T.strip (T.drop 5 input)
      case cur of
        Nothing -> appendMsg (mkMsg "system" "No session yet — use /new or send a message first." t)
        Just sid -> do
          -- 有 planning 计划时拒绝待审批步骤；没有就直接说清楚，
          -- 不要拿内核的 400 "No pending approval" 当反馈。
          plan <- liftIO (fetchPlan bridge sid)
          case plan of
            Right pv | pvPhase pv == "planning" -> do
              void $ liftIO $ async $ do
                r <- decideStep bridge sid "reject"
                writeBChan chan (EvPlanState (fmap ((, Nothing)) r))
            _ -> appendMsg (mkMsg "system"
                   (tr lang "Nothing to deny — no pending plan or approval.") t)
    "/plugins" -> do
      t <- liftIO now
      result <- liftIO (listPlugins bridge)
      case result of
        Right [] -> appendMsg (mkMsg "system" "No plugins registered." t)
        Right ps -> appendMsg (mkMsg "system"
                      ("Plugins:\n" <> T.unlines
                        [ "  - " <> pluginName p <> " " <> pluginVersion p
                            <> "  —  " <> pluginDescription p
                        | p <- ps ]) t)
        Left err -> appendMsg (mkMsg "error" (T.pack (show err)) t)
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

-- | 草稿列表的编号预览（每行一条）。
stashListing :: Lang -> [Text] -> Text
stashListing lang [] = tr lang "stash is empty"
stashListing _ entries =
  T.unlines
    [ T.pack (show i) <> ". " <> takeCells 60 (T.replace "\n" " " e)
    | (i, e) <- zip [(1 :: Int) ..] entries ]
