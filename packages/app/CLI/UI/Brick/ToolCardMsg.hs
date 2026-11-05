{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | 工具事件的卡片化：状态标签、卡片消息构造、状态映射、文本渲染。
--
-- 从 "UI.Brick.AppEvent" 拆出。纯映射，与事件分派无关，可单独测试。
module UI.Brick.ToolCardMsg
  ( statusTagOf, toolCardMsg, toCardStatus, renderToolEvent
  ) where

import Brick
import Brick.BChan
import Brick.Widgets.Border
import Brick.Widgets.Edit
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
    ( Command(..), parseCommandWith, pickerItems, pickerItemsGrouped
    , groupKey, groupTitle, helpTextFor, registryHelp )
import UI.SettingsView (SettingsEntry(..), settingsEntries, filterEntries, isOverridden, maskSecret)
import UI.State
import UI.StatusInfo (StatusRow(..), collectStatusInfo)
import UI.StatsView (StatsBlock(..), buildStatsBlocks)
import UI.I18n (Lang(..), langName, parseLang, tr)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Graphics.Vty.Attributes
import Graphics.Vty.Input.Events
import qualified Graphics.Vty as V
import Lens.Micro ((&), (.~), (%~), (^.))
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
import UI.Brick.DialogActivate
  ( dialogActivate, handleDialogKey, refreshProviderEfforts
  , startProviderRemove, toggleProviderThinking )
import UI.Brick.Palette
  ( allPickerItems, movePalette, paletteItemsFor, refreshCompletion
  , refreshPalette, runPaletteItem )
import UI.Brick.InputOps
  ( clearView, insertPaste, pasteClipboardText, pasteImage, recordVoice
  , recordVoiceNote, steerDraft )
import UI.Brick.Wizard
  ( commitWizard, finishWizard, invalidJson, refreshWizardInput
  , startWizard, startWizardPreset )
import UI.Brick.RunControl
  ( approveAndRun, decideApprovalNow, escapeHierarchy, escapeWithoutApproval
  , requestInterrupt, requestStopServices, runShellCommand, stopServicesAndHalt )
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
import UI.Render.Markdown (MdBlock(..), MdSpan(..), parseMarkdown)
import UI.Dialog
import UI.Render.ToolCard (ToolCard(..), ToolFold(..), ToolStatus(..), toolCardWithStatus, toggleFold)
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

statusTagOf :: ToolRunStatus -> Text
statusTagOf ToolRunRunning   = "running…"
statusTagOf ToolRunSucceeded = "✓"
statusTagOf (ToolRunFailed _) = "✗"

-- | Render a tool card with its status footer (message text).

toolCardMsg :: ToolEvent -> Text -> ChatMessage
toolCardMsg ev t = toolMsg "tool" card t
  where
    card = ToolCard (teName ev) (teArgs ev)
                    (Just (toCardStatus (teStatus ev))) (teDurationMs ev)
                    (maybe [] T.lines (teOutput ev))
                    (maybe "generic" tvCard (teView ev))

-- | Approve the pending step, run it as an ordinary agent turn, then report the
-- result.
--
-- The kernel only *releases* a step; running it is the host's job. The shell's
-- honest version of that job is asking the agent with the step's title, and
-- then telling the kernel how it went — otherwise the kernel's progress would
-- be a guess.
-- | approveAndRun 见 UI.Brick.RunControl。

-- | Status text for the footer/status line.
-- | statusTagOf 见 UI.Brick.AppEvent。


toCardStatus :: ToolRunStatus -> ToolStatus
toCardStatus s = case s of
  ToolRunRunning   -> ToolRunning
  ToolRunSucceeded -> ToolSucceeded
  ToolRunFailed e  -> ToolFailed e

-- | Dispatch submitted input: open the quick picker when a slash prefix is
-- ambiguous, otherwise run the command / send the chat message.
-- | handleSubmit 见 UI.Brick.ChatKeys。

-- | handleChat 见 UI.Brick.ChatKeys。

-- | expandFileReferences 见 UI.Brick.ChatKeys。


renderToolEvent :: ToolEvent -> Text
renderToolEvent ev =
  T.unlines (toolCardWithStatus (cardLabel ev) (teArgs ev)
              (toCardStatus (teStatus ev)) (teDurationMs ev))
  where
    -- DSH's `presentCall`: the tool says how this specific call should be
    -- labelled. Falls back to the tool name when the event carries no view,
    -- which is every tool today.
    cardLabel e = case teView e of
      Just v | not (T.null (tvTitle v)) -> tvTitle v
      _                                 -> T.pack (teName e)

-- | Map the wire status to the card status type.
-- | toCardStatus 见 UI.Brick.AppEvent。

-- | 设置面板组见 UI.Brick.KeyDispatch。
