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
import Brick.Widgets.Border
import Brick.Widgets.Edit
import Control.Monad.IO.Class (liftIO)
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
import UI.Commands.Registry
    ( Command(..)
    , isKnownCommand, parseCommandWith, pickerItems, pickerItemsGrouped
    , groupKey, groupTitle, helpTextFor, registryHelp )
import UI.SettingsView (SettingsEntry(..), settingsEntries, filterEntries, isOverridden, maskSecret)
import UI.Render.Picker (filterItems)
import UI.Render.ToolCard (ToolFold(..))
import UI.State
import UI.StatusInfo (StatusRow(..), collectStatusInfo)
import UI.StatsView (StatsBlock(..), buildStatsBlocks)
import UI.I18n (Lang(..), langName, parseLang, tr)
import Data.List (find)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Graphics.Vty.Attributes
import Graphics.Vty.Input.Events
import qualified Graphics.Vty as V
import Lens.Micro ((&), (.~), (%~), (^.))
import UI.Brick.ChatEditor (commitEditor, editExternally)
import UI.Brick.DialogKeys
  ( chooseProvider, dialogAppend, dialogDelete, modifyTop, persistSelection
  , scrollBottom, selectSkill, withCommands )
import UI.Brick.Apply
  ( applyLanguage, applyTheme, modeAction, openSettingsPanel )
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
import UI.PasteFold (expandPastes)
import System.Directory (doesFileExist)
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



handleSubmit :: Text -> EventM ResourceName AppState ()
handleSubmit rawInput = do
  st <- get
  -- 粘贴折叠的占位符在提交前换回原文：模型看到的必须是完整内容。
  let input = expandPastes (appPastes st) rawInput
  case shellCommandOf input of
    Just cmd -> runShellCommand cmd
    Nothing ->
      if "/" `T.isPrefixOf` input
        then -- 首词精确命中注册表 = 无歧义命令，直接执行（filterItems 的 infix
             -- 匹配会把 desc 里的字样也算候选，如 /loop 的用法示例含 "stop"，
             -- 让精确的 /stop 被误判歧义而弹模态、甚至按字母序误执行 /loop）。
             if isKnownCommand input
               then handleSlash input
               else case filterItems input (allPickerItems st) of
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
