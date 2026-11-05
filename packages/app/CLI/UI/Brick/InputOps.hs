{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | 输入区的动作：粘贴（文本/图片）、清屏、转向、语音。
--
-- 从 @UI.Brick@ 拆出。它们都由 handleChatKey 的键位分派触发，彼此不依赖，
-- 共同点是「对输入框/剪贴板/录音设备产生副作用」。
module UI.Brick.InputOps
  ( pasteImage
  , clearView
  , steerDraft
  , insertPaste
  , pasteClipboardText
  , recordVoice
  , recordVoiceNote
  ) where

import Brick
import Brick.BChan
import Brick.Widgets.Border
import Brick.Widgets.Edit
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Monad (forM_)
import Control.Monad.IO.Class (liftIO)
import Core.Clipboard (readClipboardText, saveClipboardImage)
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
import UI.Commands (executeCommand)
import UI.Commands.Registry
    ( Command(..), parseCommandWith, pickerItems, pickerItemsGrouped
    , groupKey, groupTitle, helpTextFor, registryHelp )
import UI.SettingsView (SettingsEntry(..), settingsEntries, filterEntries, isOverridden, maskSecret)
import UI.State
import UI.StatusInfo (StatusRow(..), collectStatusInfo)
import UI.StatsView (StatsBlock(..), buildStatsBlocks)
import UI.I18n (Lang(..), langName, parseLang, tr)
import Data.IORef (newIORef)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Data.Time.Clock.POSIX (getPOSIXTime)
import Graphics.Vty.Attributes
import Graphics.Vty.Input.Events
import qualified Graphics.Vty as V
import Lens.Micro ((&), (.~), (%~), (^.))
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
import UI.Brick.DialogActivate
  ( dialogActivate, handleDialogKey, refreshProviderEfforts
  , startProviderRemove, toggleProviderThinking )
import UI.Brick.Palette
  ( allPickerItems, movePalette, paletteItemsFor, refreshCompletion
  , refreshPalette, runPaletteItem )
import UI.Brick.Wizard
  ( commitWizard, finishWizard, invalidJson, refreshWizardInput
  , startWizard, startWizardPreset )
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
import UI.PasteFold (isLongPaste, pasteLabel)
import System.Directory (createDirectoryIfMissing, getHomeDirectory, getFileSize)
import System.FilePath ((</>), takeDirectory, takeFileName)
import System.Process (readProcessWithExitCode)
import System.Exit (ExitCode(..))
import Control.Exception (IOException, catch, try)
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

-- | Ctrl+V: attach a clipboard image.  The image is saved under
-- ~/.trha/paste and inserted as a path reference (the read tool can open
-- it; the model's multimodal channel is not wired yet).
pasteImage :: EventM ResourceName AppState ()
pasteImage = do
  lang <- gets appLang
  r <- liftIO saveClipboardImage
  case r of
    Nothing -> showToast (tr lang "No image in clipboard")
    Just path -> do
      modify $ \s -> s
        { appInput = editorText InputArea (Just 1)
            (editorValue s <> " [image: " <> T.pack path <> "]") }
      showToast (tr lang "Image saved: " <> T.pack path)

-- | ctrl+l：清空消息视图；历史保留在 transcript 里（/resume 仍可回放）。
clearView :: EventM ResourceName AppState ()
clearView = do
  modify $ \s -> s { appMessages = [], appFolds = Map.empty, appCardFocus = Nothing }
  scrollBottom

-- | ctrl+enter：把当前输入作为 steer 注入运行中的回合；空闲时忽略
-- （空闲下这个键多半是想换行，不能悄悄发出去）。
steerDraft :: EventM ResourceName AppState ()
steerDraft = do
  st <- get
  let input = T.strip (editorValue st)
  case appSessionId st of
    Just sid | appBusy st && not (T.null input) -> do
      t0 <- liftIO now
      ref <- liftIO (newIORef (Just sid))
      mref <- liftIO (newIORef (appModel st))
      r <- liftIO (executeCommand (appLang st) (appBridge st) ref mref (Steer input))
      forM_ r $ \out -> appendMsg (mkMsg "system" out t0)
      modify $ \s -> s { appInput = editorText InputArea (Just 1) "" }
      scrollBottom
    _ -> pure ()

-- | shift+insert：把剪贴板文本插到输入末尾。
-- | 粘贴一段文本：长内容折叠成占位符，短内容直接进编辑器。
-- 终端的 bracketed paste（EvPaste）与剪贴板粘贴（alt+v）共用这一条。
insertPaste :: Text -> EventM ResourceName AppState ()
insertPaste txt = do
  st <- get
  let n = appPasteSeq st + 1
      nlines = T.count "\n" txt + 1
      label = pasteLabel n nlines
      folded = isLongPaste txt
  modify $ \s -> s
    { appPastes = if folded then appPastes s <> [(label, txt)] else appPastes s
    , appPasteSeq = if folded then n else appPasteSeq s
    , appInput = editorText InputArea (Just 1)
        (editorValue s <> (if folded then label else txt)) }
  refreshCompletion >> refreshPalette
  scrollBottom

pasteClipboardText :: EventM ResourceName AppState ()
pasteClipboardText = do
  st <- get
  mt <- liftIO readClipboardText
  case mt of
    Nothing -> showToast (tr (appLang st) "No text on the clipboard")
    Just txt -> insertPaste txt

-- | Ctrl+R: record a short voice note.  The recorder takes over the
-- terminal (arecord needs a device handle), then the saved path is inserted
-- as an attachment reference.  Transcription needs an external service.
recordVoice :: EventM ResourceName AppState ()
recordVoice = do
  lang <- gets appLang
  st <- get
  resultVar <- liftIO newEmptyMVar
  suspendAndResume $ do
    r <- recordVoiceNote
    putMVar resultVar r
    pure st
  r <- liftIO (takeMVar resultVar)
  case r of
    Nothing -> showToast (tr lang "Recording unavailable")
    Just p -> do
      -- Prefer the transcript; an unconfigured/failed ASR keeps the path so
      -- the recording is never lost (MiMo's fallback behaviour).
      transcript <- liftIO (transcribeVoice (appBridge st) (T.pack p))
      case transcript of
        Right text -> do
          modify $ \s -> s
            { appInput = editorText InputArea (Just 1) (editorValue s <> " " <> text) }
          showToast (tr lang "Transcribed")
        Left _ -> do
          modify $ \s -> s
            { appInput = editorText InputArea (Just 1)
                (editorValue s <> " [voice: " <> T.pack p <> "]") }
          showToast (tr lang "Voice saved: " <> T.pack p)

-- | Record 5 s of mono 16 kHz audio with arecord (ALSA).  'Nothing' when the
-- recorder or the input device is missing.
recordVoiceNote :: IO (Maybe FilePath)
recordVoiceNote = do
  home <- getHomeDirectory
  let dir = home </> ".trha" </> "voice"
  createDirectoryIfMissing True dir
  t <- getPOSIXTime
  let out = dir </> ("voice-" <> show (round (t * 1000) :: Int) <> ".wav")
  r <- try (readProcessWithExitCode "arecord"
              ["-q", "-d", "5", "-f", "S16_LE", "-r", "16000", "-c", "1", out] "")
         :: IO (Either IOException (ExitCode, String, String))
  case r of
    Right (ExitSuccess, _, _) -> do
      sz <- getFileSize out `catch` \(_ :: IOException) -> pure 0
      pure (if sz > 44 then Just out else Nothing)  -- 44 = WAV header
    _ -> pure Nothing
