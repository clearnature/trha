{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | 供应商向导：新建/编辑供应商的分步表单。
--
-- 从 @UI.Brick@ 拆出。整条链（open / step / commit / finish）共享
-- ProviderWizard 状态机，所以作为一个模块推进。
module UI.Brick.Wizard
  ( refreshWizardInput
  , invalidJson
  , finishWizard
  , commitWizard
  , startWizard
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
  ( beginSel, extendSel, copySelectionText, finishSel, copyToClipboard )
import UI.Brick.Input
  ( alwaysConfirmText, editorCursor, editorValue, promptIsEmpty )
import UI.Brick.SessionView
  ( blocksToMessages, localSessionLines, refreshSidebar, resumeSession )
import UI.Brick.Chat (handleChatWith)
import UI.Brick.Slash (handleSlash)
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

refreshWizardInput :: ProviderWizard -> EventM ResourceName AppState ()
refreshWizardInput w = do
  modify $ \s -> s { appWizard = Just w
                   , appInput = editorText InputArea (Just 1) (wizardValue w (pwStep w)) }

-- | Take the editor's text as the current field and advance (or save).

-- | 判断一段文本是否是「非空但 JSON 非法」——向导用它拦住不合法的 extra body。
invalidJson :: Text -> Bool
invalidJson t
  | T.null (T.strip t) = False
  | otherwise = case (decode (BL.fromStrict (TE.encodeUtf8 t)) :: Maybe Value) of
      Just _  -> False
      Nothing -> True

finishWizard :: ProviderWizard -> EventM ResourceName AppState ()
finishWizard w = do
  st <- get
  let name = T.strip (pwName w)
      base = T.strip (pwBaseUrl w)
      kind0 = T.toLower (T.strip (pwKind w))
      kind = if kind0 `elem` ["openai", "anthropic", "responses"] then kind0 else "openai"
      models = [ T.strip m | m <- T.splitOn "," (pwModels w)
               , not (T.null (T.strip m)) ]
      def = if T.null (T.strip (pwDefault w))
              then fromMaybe "" (listToMaybe models)
              else T.strip (pwDefault w)
      authHeader = T.toLower (T.strip (pwAuthHeader w)) `notElem` ["no", "false", "0"]
      noProxy = T.toLower (T.strip (pwNoProxy w)) `elem` ["yes", "true", "1"]
      effort = T.strip (pwEffort w)
      vision = [ T.strip v | v <- T.splitOn "," (pwVision w)
               , not (T.null (T.strip v)) ]
      jsonOf t | T.null (T.strip t) = Nothing
               | otherwise = decode (BL.fromStrict (TE.encodeUtf8 t))
      headersV = jsonOf (pwHeaders w)
      extraBodyV = jsonOf (pwExtraBody w)
      -- thinking.type is an Anthropic-wire field; the OpenAI/Responses wires
      -- ignore it, so do not persist a value that can never take effect.
      thinking0 = T.strip (pwThinking w)
      thinking = if kind == "anthropic" then thinking0 else ""
      responsesMode = T.strip (pwResponsesMode w)
      ctxWindow = case reads (T.unpack (T.strip (pwCtxWindow w))) :: [(Int, String)] of
        [(n, "")] | n > 0 -> Just n
        _                 -> Nothing
  if T.null name || T.null base
    then modify $ \s -> s { appWizard = Nothing
                           , appInput = editorText InputArea (Just 1) ""
                           , appStatus = tr (appLang s) "Provider needs a name and a base URL" }
    else do
      modify $ \s -> s { appWizard = Nothing
                       , appInput = editorText InputArea (Just 1) ""
                       , appStatus = tr (appLang s) "Saving provider..." }
      let bridge = appBridge st
          chan = appChan st
      void $ liftIO $ async $ do
        -- Probe first: a reachable endpoint tells us its models, default,
        -- effort ladder and vision models.  Anything the user typed wins;
        -- an unreachable endpoint still saves (the draft is manual).
        probe <- probeProvider bridge base (T.strip (pwKey w))
        let (models', def', effort', vision', efforts') = case probe of
              Right p -> ( if null models then ppModels p else models
                         , if T.null def then ppDefault p else def
                         , if T.null effort then ppEffort p else effort
                         , if null vision then ppVision p else vision
                         , ppEfforts p )
              Left _  -> (models, def, effort, vision, [])
        r <- saveProvider bridge name kind base (T.strip (pwKey w)) models' def'
                            authHeader noProxy effort' vision' efforts'
                            headersV extraBodyV thinking responsesMode ctxWindow
        writeBChan chan (EvProviderSaved r)


commitWizard :: EventM ResourceName AppState ()
commitWizard = do
  st <- get
  case appWizard st of
    Nothing -> return ()
    Just w -> do
      let value = T.strip (editorValue st)
          w' = wizardSet (pwStep w) value w
      if pwStep w >= 14
        then
          -- A malformed JSON object must not be silently dropped: keep the
          -- wizard open and say which field is wrong.
          if invalidJson (pwHeaders w') || invalidJson (pwExtraBody w')
            then modify $ \s -> s
                   { appStatus = tr (appLang s)
                       "Invalid JSON in extra headers/body (use a JSON object or leave it blank)" }
            else finishWizard w'
        else do
          let n = pwStep w + 1
          modify $ \s -> s { appStatus = tr (appLang s) "Provider wizard "
                                 <> T.pack (show (n + 1)) <> "/15: "
                                 <> wizardPrompts !! n }
          refreshWizardInput w' { pwStep = n }

startWizard :: Maybe ProviderInfo -> EventM ResourceName AppState ()
startWizard existing = do
  let w = case existing of
        Nothing -> ProviderWizard 0 "" "openai" "" "" "" "" "" "" "yes" "no" "" "" "" "" ""
        Just p  -> ProviderWizard 0 (piName p) (piKind p) (piBaseUrl p)
                     (T.intercalate "," (piModels p)) (piDefault p) ""
                     (piEffort p)
                     (T.intercalate "," (piVision p))
                     (if piAuthHeader p then "yes" else "no")
                     (if piNoProxy p then "yes" else "no")
                     (maybe "" (TE.decodeUtf8 . BL.toStrict . encode) (piHeaders p))
                     (maybe "" (TE.decodeUtf8 . BL.toStrict . encode) (piExtraBody p))
                     (piThinking p)
                     (piResponsesMode p)
                     (maybe "" (T.pack . show) (piContextWindow p))
  modify $ \s -> s { appWizard = Just w
                   , appDialogs = stackPop (appDialogs s)
                   , appPalette = Nothing
                   , appInput = editorText InputArea (Just 1) ""
                   , appStatus = tr (appLang s) "Provider wizard 1/6: "
                       <> head wizardPrompts }
  refreshWizardInput w
