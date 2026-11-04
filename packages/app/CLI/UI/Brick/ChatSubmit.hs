{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | 提交路径：技能提交、编辑器提交、外挂编辑器、回车提交与 @文件展开。
--
-- 从 "UI.Brick.ChatKeys" 拆出。handleChatKey/handleChatEnter 是「按了什么键」，
-- 这里回答「回车之后做什么」——依赖单向：按键 → 提交。
module UI.Brick.ChatSubmit
  ( submitSkill, commitEditor, editExternally, handleSubmit
  , handleChat, expandFileReferences
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
import UI.InputHistory (HistState(..), emptyHistState, histUp, histDown, histCommit, loadHistory, appendHistory)

submitSkill :: Text -> Text -> EventM ResourceName AppState ()
submitSkill name args = do
  st <- get
  case find ((== name) . skName) (appSkills st) of
    Nothing -> do
      t <- liftIO now
      appendMsg (mkMsg "system" (tr (appLang st) "Unknown skill: " <> name) t)
      scrollBottom
    Just sk -> do
      read_ <- liftIO (try (TIO.readFile (skPath sk)) :: IO (Either IOException Text))
      case read_ of
        Left _ -> do
          t <- liftIO now
          appendMsg (mkMsg "system"
            (tr (appLang st) "Cannot read skill file: " <> T.pack (skPath sk)) t)
          scrollBottom
        Right body -> do
          let key = "/skill:" <> skName sk
              frec' = recordUse key (appFrecency st)
          liftIO (saveFrecency frec')
          modify $ \s -> s { appFrecency = frec' }
          let visible = T.stripEnd ("/skill:" <> skName sk <> " " <> args)
          commitEditor visible
          handleChatWith visible (skillTurn sk body args)

-- | Move the current editor text into history and clear the editor.

commitEditor :: Text -> EventM ResourceName AppState ()
commitEditor input = do
  liftIO (appendHistory input)
  modify $ \s -> s { appInput = editorText InputArea (Just 1) ""
                   , appHist = histCommit input (appHist s)
                   , appComp = Nothing
                   , appPalette = Nothing }

-- | Pass an event through to the brick editor (default editing keys:
-- alt+enter inserts a newline; cursor movement; pastes).
-- | editDefaultKey / cursorRow 见 UI.Brick.ChatKeys。

-- | Toggle the most recent tool card (ctrl+o, or enter on empty input).
-- | ctrl+e: edit the composer in @$EDITOR@.  The TUI suspends while the
-- editor owns the terminal, then the saved text replaces the composer.

editExternally :: EventM ResourceName AppState ()
editExternally = do
  st <- get
  let text = editorValue st
  (path, ed) <- liftIO $ do
    tmp <- getTemporaryDirectory
    (path, h) <- openTempFile tmp "trha-edit.txt"
    TIO.hPutStr h text
    hClose h
    e <- do
      v <- lookupEnv "EDITOR"
      case v of
        Just e' | not (null e') -> pure e'
        _ -> do
          v2 <- lookupEnv "VISUAL"
          case v2 of
            Just e2 | not (null e2) -> pure e2
            -- Windows 原生环境无 vi（tui-port L80 同款死角）：否则
            -- readProcess 抛 IOException 且 putMVar 不执行，takeMVar
            -- 永久阻塞把 TUI 挂死。
            _ -> do
              mSpec <- lookupEnv "ComSpec"
              pure (maybe "vi" (const "notepad") mSpec)
    pure (path, e)
  resultVar <- liftIO newEmptyMVar
  suspendAndResume $ do
    -- editor 缺失/异常也要 putMVar，否则 takeMVar 阻塞挂死 TUI。
    r <- try (readProcessWithExitCode ed [path] "")
    putMVar resultVar $ case (r :: Either IOException (ExitCode, String, String)) of
      Right (code, _, _) -> code
      Left _ex           -> ExitFailure 127  -- command-not-found 惯例
    pure st
  code <- liftIO (takeMVar resultVar)
  body <- liftIO $ TIO.readFile path `catch` \(_ :: IOException) -> pure text
  liftIO $ removeFile path `catch` \(_ :: IOException) -> pure ()
  case code of
    ExitSuccess ->
      modify $ \s -> s { appInput = editorText InputArea (Just 1) (T.stripEnd body) }
    ExitFailure n ->
      showToast ("editor exited " <> T.pack (show n))

-- | Run one posture action (cycle / yolo / set) and reflect the answer in
-- the footer.  Modes are session state: without a session there is nothing
-- to switch.
-- | modeAction 见 UI.Brick.Apply。

-- | Show a transient notice and schedule its dismissal.  The stamp keeps a
-- late timer from clearing a newer toast.
-- | showToast 见 UI.Brick.Toast。

-- | Pull the session's posture (after creation/restore).

handleSubmit :: Text -> EventM ResourceName AppState ()
handleSubmit rawInput = do
  st <- get
  -- 粘贴折叠的占位符在提交前换回原文：模型看到的必须是完整内容。
  let input = expandPastes (appPastes st) rawInput
  case shellCommandOf input of
    Just cmd -> runShellCommand cmd
    Nothing ->
      if "/" `T.isPrefixOf` input
        then case filterItems input (allPickerItems st) of
          []  -> handleSlash input
          [_] -> handleSlash input
          _   -> modify $ \s -> s { appDialogs =
                   stackPush (DialogCommands (allPickerItems st) input 0) (appDialogs s) }
        else handleChat input

-- | 粘贴折叠的纯逻辑（判定、占位符、展开）在 UI.PasteFold 里，可单测。

-- | Run one local shell command and show its output as a card.  120s cap, 20k
-- character cap; the exit code is appended when non-zero.  The execution
-- contract lives in 'runLocalShell' so the REPL's @/shell@ behaves identically.
-- | runShellCommand 见 UI.Brick.RunControl。

-- | handleSlash 见 UI.Brick.Slash。

-- | Send a chat message: create session lazily, send async, never block UI.
-- While the step runs, tool lifecycle events arrive over SSE; they are
-- recorded to the transcript and surfaced through 'EvTool'.

handleChat :: Text -> EventM ResourceName AppState ()
handleChat input = do
  -- DSH's `context/file-reference`: `@path` becomes the file's body. Expanded
  -- here (not in the scheduler) because the path is relative to the user's cwd.
  expanded <- liftIO (expandFileReferences input)
  handleChatWith input expanded

-- | Expand `@path` references in a prompt into fenced file bodies.
--
-- Ported from `deepseek-harness/packages/context/file-reference`: a token that
-- starts with `@` and names an existing file is kept and followed by that file's
-- contents, so the model reads it without spending a tool round trip.
--
-- A missing path — or a stray `@` in ordinary prose — is left untouched:
-- expansion must never turn a typo into a failed turn. Bodies are capped at the
-- same size the `read` tool caps at.

expandFileReferences :: Text -> IO Text
expandFileReferences input
  | not (T.any (== '@') input) = pure input
  | otherwise = T.unwords <$> mapM expand (T.words input)
  where
    expand tok
      | T.length tok > 1 && "@" `T.isPrefixOf` tok && not ("@@" `T.isPrefixOf` tok) = do
          let p = T.unpack (T.drop 1 tok)
          isFile <- doesFileExist p
          if not isFile
            then pure tok
            else do
              body <- try (TIO.readFile p) :: IO (Either IOException Text)
              pure $ case body of
                Left _ -> tok
                Right b ->
                  let capped = if T.length b > 20000
                                 then T.take 20000 b <> "\n… (file truncated)"
                                 else b
                   in tok <> "\n```\n" <> capped <> "\n```"
      | otherwise = pure tok

-- | 'handleChat' with a separate visible text.  A skill sends its instructions
-- as the model turn while the transcript/UI keeps the @/skill:<name>@ trigger
-- (MiMo's split: visible message + body injected as context).
-- | handleChatWith 见 UI.Brick.Chat。

-- | Localised /help text (command list + picker/key hints).
-- | helpTextFor 见 UI.Commands.Registry。


-- /settings panel -- port of the qwen-code SettingsDialog interaction:
-- a tab bar (Settings / Status / Stats) plus a focus model where the
-- keyboard moves between the tab bar and the list (and into value editing).
--   keys:  left/right  switch tab (any focus)
--          up          list top -> tab bar    down: tab bar -> list
--          enter       tab bar: activate list | list: edit/toggle value
--          type        filter list (search)  esc: close / cancel edit

-- SettingsTab / SettingsFocus / SettingsPanel live in "UI.State".


-- | settingsRows / visibleRows 见 UI.Brick.Draw.Settings。

-- | Open the panel with a fresh effective configuration snapshot.
-- | openSettingsPanel 见 UI.Brick.Apply。

-- | Close the /settings panel.
