{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | 配置类斜杠命令：@/settings@、@/sandbox@、@/theme@、@/verbose@、@/mode@。
--
-- 从 "UI.Brick.Slash" 拆出（认领式分派）。
module UI.Brick.Slash.Config
  ( handleConfigSlash
  ) where

import Brick
import Brick.BChan
import Brick.Widgets.Border
import Brick.Widgets.Edit
import Control.Monad (forM_)
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
import UI.Commands (runSettingsCommand)
import UI.Commands.Registry
    ( Command(..), parseCommandWith, pickerItems, pickerItemsGrouped
    , groupKey, groupTitle, helpTextFor, registryHelp )
import UI.SettingsView (SettingsEntry(..), settingsEntries, filterEntries, isOverridden, maskSecret)
import UI.State
import UI.StatusInfo (StatusRow(..), collectStatusInfo)
import UI.StatsView (StatsBlock(..), buildStatsBlocks)
import UI.I18n (Lang(..), langName, parseLang, tr)
import Config.Settings (resolveConfig, saveConfig)
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
import System.FilePath ((</>), takeDirectory, takeFileName)
import System.Exit (ExitCode(..))
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

handleConfigSlash :: CmdCtx -> Maybe (EventM ResourceName AppState ())
handleConfigSlash cx = case cxCmd cx of
  "/settings" -> Just $ slashSettings cx
  "/sandbox"  -> Just $ slashSandbox cx
  "/theme"    -> Just $ slashTheme cx
  "/verbose"  -> Just $ slashVerbose cx
  _ | (cxCmd cx) == "/mode" || "/mode " `T.isPrefixOf` (cxCmd cx) -> Just $ slashMode cx
  _ | (cxCmd cx) == "/language" || "/language " `T.isPrefixOf` (cxCmd cx) -> Just $ slashLanguage cx
  _ -> Nothing

-- | @/settings@：无参数打开设置面板，带参数走设置命令。
slashSettings :: CmdCtx -> EventM ResourceName AppState ()
slashSettings cx
  | T.null (T.strip (T.drop 9 (cxInput cx))) = openSettingsPanel
  | otherwise = do
      let arg = T.strip (T.drop 9 (cxInput cx))
      msg <- liftIO (runSettingsCommand (cxLang cx) arg)
      forM_ msg $ \m -> appendMsg (mkMsg "system" m (cxTime cx))
      scrollBottom

-- | @/sandbox@：打开沙箱配置对话框。
slashSandbox :: CmdCtx -> EventM ResourceName AppState ()
slashSandbox _ = modify $ \s -> s { appDialogs =
  stackPush (DialogSandbox (appSandbox s) 0) (appDialogs s) }

-- | @/theme@：无参数打开主题列表，带参数直接切换。
slashTheme :: CmdCtx -> EventM ResourceName AppState ()
slashTheme cx = do
  let arg = T.strip (T.drop 6 (cxInput cx))
  if T.null arg
    then modify $ \s -> s { appDialogs =
           stackPush (DialogThemes themes 0) (appDialogs s) }
    else applyTheme arg

-- | @/verbose@：翻转详细模式。
slashVerbose :: CmdCtx -> EventM ResourceName AppState ()
slashVerbose cx = do
  v <- gets appVerbose
  modify $ \s -> s { appVerbose = not v }
  showToast (if v then tr (cxLang cx) "Verbose off" else tr (cxLang cx) "Verbose on")

-- | @/mode@：cycle 或 set（带参数必须走 modeAction，否则状态栏停在旧姿态）。
slashMode :: CmdCtx -> EventM ResourceName AppState ()
slashMode cx = do
  let arg = T.strip (T.drop 5 (cxInput cx))
  if T.null arg
    then modeAction (object ["action" .= ("cycle" :: Text)])
    else modeAction (object ["action" .= ("set" :: Text), "mode" .= arg])

-- | @/language@：无参数打开语言列表，带参数直接切换并落盘。
slashLanguage :: CmdCtx -> EventM ResourceName AppState ()
slashLanguage cx = do
  cfg <- liftIO (resolveConfig defaultCLIConfig)
  let raw = T.strip (T.drop (T.length "/language") (cxInput cx))
      available = T.intercalate ", " (map langName ([minBound .. maxBound] :: [Lang]))
  if T.null raw
    then modify $ \s -> s { appDialogs =
           stackPush (DialogLanguages ([minBound .. maxBound] :: [Lang]) 0) (appDialogs s) }
    else do
      let l = parseLang raw
      liftIO (saveConfig (cfg { configLang = langName l }))
      modify $ \s -> s { appLang = l, appStatus = tr l "Language: " <> langName l }
      appendMsg (mkMsg "system"
        (tr l "Language: " <> langName l <> "\n" <> tr l "available: " <> available) (cxTime cx))
