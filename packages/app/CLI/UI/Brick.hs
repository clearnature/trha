{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE ScopedTypeVariables #-}

module UI.Brick
  ( -- * Brick UI
    AppState(..)
  , ChatMessage(..)
  , AppEvent(..)
  , ResourceName(..)
  , appFor
  , initialState
  , runTUI
  ) where

import Brick
import Brick.BChan
import Brick.Widgets.Border
import Brick.Widgets.Edit
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async)
import Control.Monad (filterM, forM_, forever, void)
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
import Core.ProjectStore (ensureProject)
import Core.Transcript (listLocalSessionsIn)
import UI.Commands.Registry
    ( Command(..), parseCommandWith, pickerItems, pickerItemsGrouped
    , groupKey, groupTitle, helpTextFor, registryHelp )
import UI.SettingsView (SettingsEntry(..), settingsEntries, filterEntries, isOverridden, maskSecret)
import UI.State
import UI.StatusInfo (StatusRow(..), collectStatusInfo)
import UI.StatsView (StatsBlock(..), buildStatsBlocks)
import UI.I18n (Lang(..), langName, parseLang, tr)
import Data.List (find)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Data.Time.Clock (getCurrentTime)
import Data.Time.LocalTime (getCurrentTimeZone)
import Graphics.Vty.Attributes
import Graphics.Vty.Config (defaultConfig)
import Graphics.Vty.CrossPlatform (mkVty)
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
import UI.Brick.KeyDispatch
  ( disarmLeader, handleCtrlCKey, handleCtrlDKey, handleEvent, handleLeaderKey )
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
  ( drawStatus, gitBranchText, gitStatText, modelLabel, pricesOf, statusLine
  , statusSandboxTag, statusClock, statusModelLine, statusGitLine, statusStatsLine )
import UI.Render.Footer (FooterLive(..), footerMetrics, parseMetrics, branchFromHead, statusFitsOneRow, wrapStatusLine)
import UI.Render.Spans
  ( SpanTok(..), boolText, diffAttrOf, fillLines, isCompactionMark
  , spanToks, splitAtWidth, spinnerFrame, todoGlyph, truncLine )
import System.Directory (getCurrentDirectory, doesFileExist)
import System.FilePath ((</>), takeDirectory, takeFileName)
import System.Environment (getEnvironment, lookupEnv)
import System.IO (hFlush, hPutStr, stdout, stderr, hIsTerminalDevice)
import System.Exit (ExitCode(..))
import Control.Exception (SomeException, catch)
import Core.RunLog (logLine)
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
import UI.IndexCache (scanProjectCached)
import UI.Keys (LeaderAction(..), leaderResolve, leaderHelp, CtrlCAction(..), decideCtrlC, decideCtrlD)
import UI.Skills (Skill(..), scanSkills, skillDirs, parseSkillInvocation, skillTurn)
import UI.CustomCommands (CustomCommand(..), loadCustomCommands, renderCustomCommand)
import UI.Stash (Stash(..), emptyStash, stashPush, stashPop, stashEntries, loadStash, saveStash)
import UI.Frecency (Frecency(..), emptyFrecency, recordUse, rankItems, loadFrecency, saveFrecency)
import UI.ModelPrefs (ModelPrefs(..), emptyModelPrefs, toggleFavorite, recordRecent, orderedModels, loadModelPrefs, saveModelPrefs)
import Data.Time.Clock (diffUTCTime)
import UI.InputHistory (HistState(..), emptyHistState, histUp, histDown, histCommit, loadHistory, appendHistory)
import UI.Render.Picker (PickerItem(..), filterItems, maxVisible, moveSelection, queryAppend, queryDelete, windowRange, buildPalette, isSection, firstSelectable)
import UI.ProviderPresets (Preset(..), presets, prePopular)
import UI.Render.ToolCard (ToolStatus(..), ToolCard(..), ToolFold(..), toggleFold, toolCardWithStatus, toolStatusLine, cardWidth)
import qualified UI.TextWidth as TW
import UI.Theme
    ( ColorSpec(..), TermColor(..), TermStyle(..), Theme, themeColors, themeName
    , defaultTheme, themes, resolveTheme, themeFor, supportsTrueColor )

-- | Provider wizard state and helpers live in "UI.State".


-- | Application state lives in "UI.State" (split out for readability).


-- | Chat payload, resource names and the settings panel live in "UI.State".


-- | Create initial state
-- | TRHA_SANDBOX=on/1/true/enforce enables the sandbox badge.
sandboxOn :: Maybe String -> Bool
sandboxOn v = case fmap (T.toLower . T.strip . T.pack) v of
  Just x | x `elem` ["on", "1", "true", "enforce"] -> True
  _ -> False

initialState :: SchedulerBridge -> BChan AppEvent -> CLIConfig -> AppState
initialState bridge chan cfg = AppState
  { appMessages  = []
  , appNextMsgId = 0
  , appInput     = editorText InputArea (Just 1) ""
  , appSessionId = Nothing
  , appModel     = configModel cfg
  , appEffort    = configEffort cfg
  , appStatus    = tr lang "Ready"
  , appBusy      = False
  , appPending   = Nothing
  , appLastUsage = Nothing
  , appHist      = emptyHistState
  , appDialogs   = emptyStack
  , appEscLast   = Nothing
  , appQuitLast  = Nothing
  , appBridge    = bridge
  , appChan      = chan
  , appLang      = lang
  , appSettings  = Nothing
  , appEffCfg    = cfg
  , appSysRows   = []
  , appMetrics   = []
  , appGitStat   = ""
  , appCostSum   = 0
  , appLastCost  = 0
  , appSessTokens = 0
  , appNow       = Nothing
  , appTz        = Nothing
  , appPlan      = Nothing
  , appFolds     = Map.empty
  , appRunningTools = Map.empty
  , appSelStart  = Nothing
  , appSelEnd    = Nothing
  , appCardFocus = Nothing
  , appMode      = Nothing
  , appSandbox   = defaultSandboxSettings
  , appCacheNow  = Nothing
  , appCacheSum  = (0, 0)
  , appCacheTurns = 0
  , appCtxUsed   = Nothing
  , appToast     = Nothing
  , appRoute     = RouteHome
  , appRecent    = []
  , appStash     = emptyStash
  , appCwd       = Nothing
  , appFiles     = []
  , appGoal      = Nothing
  , appInstructions = []
  , appFrecency  = emptyFrecency
  , appModelPrefs = emptyModelPrefs
  , appTheme      = defaultTheme
  , appAgents     = []
  , appVerbose    = False
  , appLsp        = []
  , appMcp        = []
  , appBalance    = Nothing
  , appTurnStart  = Nothing
  , appLastTps    = Nothing
  , appLastDecodeTps = Nothing
  , appFirstToken = Nothing
  , appApproval  = Nothing
  , appAskTool   = Nothing
  , appPastes    = []
  , appPasteSeq  = 0
  , appAskAt     = Nothing
  , appPendingDelete = Nothing
  , appPendingStop   = False
  , appPendingProviderRemove = Nothing
  , appUsage     = Nothing
  , appCtxSize   = configCtxSize cfg
  , appSidebar   = SidebarAuto
  , appTodos     = []
  , appSessionTitle = Nothing
  , appIndex     = []
  , appComp      = Nothing
  , appPalette   = Nothing
  , appLeader    = False
  , appProvider  = if T.null (T.strip (configProvider cfg))
                     then Nothing else Just (T.strip (configProvider cfg))
  , appProviders = []
  , appSkills    = []
  , appCustomCmds = []
  , appWizard    = Nothing
  }
  where lang = parseLang (configLang cfg)

-- | Application for a given theme (attribute map follows the palette).
appFor :: App AppState AppEvent ResourceName
appFor = App
  { appDraw         = drawUI
  , appChooseCursor = showFirstCursor
  , appHandleEvent  = handleEvent
  , appStartEvent   = do
      st <- get
      -- Sandbox badge: env is the first guess; the scheduler's effective
      -- switch (config + runtime) arrives asynchronously and wins.
      liftIO (lookupEnv "TRHA_SANDBOX") >>= \v -> modify $ \s0 ->
        s0 { appSandbox = (appSandbox s0) { ssEnabled = sandboxOn v } }
      void $ liftIO $ async $ do
        r <- fetchSandboxConfig (appBridge st)
        writeBChan (appChan st) (EvSandboxConfig r)
      -- Window title: the terminal tab should name the workspace.
      liftIO $ hPutStr stdout
        ("\ESC]0;trha — " <> T.unpack (fromMaybe "agent" (appCwd st)) <> "\a")
      -- vty 6's defaultConfig does not enable mouse reporting, so clicking
      -- any widget (the thinking triangle included) never produced an event.
      -- Open it explicitly here; /mouse off switches to native selection.
      liftIO $ do
        hPutStr stdout $
          if configMouseCapture (appEffCfg st)
            then "\ESC[?1000h\ESC[?1006h"
            else "\ESC[?1000l\ESC[?1002l\ESC[?1003l\ESC[?1006l"
        hFlush stdout
      -- 每秒一次 tick：时钟与「本轮耗时」原本只在按键事件里更新，
      -- 静止的会话状态栏会停在旧时间上。
      void $ liftIO $ async $ forever $ do
        threadDelay 1000000
        writeBChan (appChan st) EvTick
  , appAttrMap      = themeAttrMap . appTheme
  }

-- | Build a brick attribute map from a UI theme.
themeAttrMap :: Theme -> AttrMap
themeAttrMap th = attrMap defAttr
  [ (attrName (T.unpack role), toVtyAttr cs)
  | (role, cs) <- themeColors th
  ]

-- | Map a theme colour spec to a vty attribute.
toVtyAttr :: ColorSpec -> Attr
toVtyAttr (ColorSpec fgCol styles) =
  foldr (\st a -> a `withStyle` toVtyStyle st) (vtyFg fgCol) styles

toVtyStyle :: TermStyle -> Style
toVtyStyle StyleBold = bold
toVtyStyle StyleDim  = dim
toVtyStyle StyleReverse = reverseVideo

-- | Map a theme colour token to a vty foreground attribute.
vtyFg :: TermColor -> Attr
vtyFg c = fg $ case c of
  Black        -> black
  Red          -> red
  Green        -> green
  Yellow       -> yellow
  Blue         -> blue
  Magenta      -> magenta
  Cyan         -> cyan
  White        -> white
  BrightBlack  -> brightBlack
  BrightRed    -> brightRed
  BrightGreen  -> brightGreen
  BrightYellow -> brightYellow
  BrightBlue   -> brightBlue
  BrightMagenta-> brightMagenta
  BrightCyan   -> brightCyan
  BrightWhite  -> brightWhite
  RGB r g b    -> rgbColor r g b

-- | Run the TUI with the named theme (unknown names fall back to default).
runTUI :: SchedulerBridge -> CLIConfig -> IO ()
runTUI bridge cfg = do
  tStart <- getCurrentTime
  -- 启动探针：只写日志（brick 之后会接管终端，届时 putStrLn 会撕坏画面）。
  -- 排查「界面出不来」时，~/.trha/logs/trha-<date>.log 里的 probe 行就是时间线。
  outTty <- hIsTerminalDevice stdout
  errTty <- hIsTerminalDevice stderr
  logLine (T.concat [ "probe tui.start stdout_tty=", boolText outTty
                    , " stderr_tty=", boolText errTty ])
  chan <- newBChan 20
  -- static footer metrics are sampled once (workspace path, git branch);
  -- the active model's context size is fetched for the occupancy segment
  _ <- async $ (do
    ws <- getCurrentDirectory
    -- Per-project index (~/.trha/projects/<slug>/) — creates it on first use.
    ensureProject ws
    gb <- gitBranchText
    writeBChan chan (EvMetrics [("workspace", T.pack ws), ("git", gb)])
    stat <- gitStatText
    writeBChan chan (EvGitStat stat)
    balance <- fetchBalance bridge
    writeBChan chan (EvBalance balance)
    models <- listModels bridge
    forM_ models $ \ms ->
      forM_ (find (\m -> modelName m == configModel cfg) ms) $ \m ->
        writeBChan chan (EvCtxSize (modelContextSize m))
    -- @-file completion index: scanned once at startup, off the UI thread.
    index <- scanProjectCached defaultIndexOptions ws
    writeBChan chan (EvCompletionIndex index)
    -- Skills: project .agents first, then home; refreshed once at startup.
    dirs <- skillDirs ws
    skills <- scanSkills dirs
    writeBChan chan (EvSkills skills)
    -- Home route: the local transcripts of *this project* only.
    recent <- listLocalSessionsIn ws
    writeBChan chan (EvRecent recent)
    -- Sidebar: cwd, a few files, and which instruction files exist.
    instrs <- filterM (doesFileExist . (ws </>)) ["AGENTS.md", "REASONIX.md", "QWEN.md", "CLAUDE.md"]
    writeBChan chan (EvSidebarInfo (Just (T.pack ws)) (take 5 (map compPath index)) (map T.pack instrs)))
    `catch` \(e :: SomeException) ->
      logLine ("probe startup-data failed: " <> T.pack (show e))
  env <- getEnvironment
  let theme = themeFor (configTheme cfg) (supportsTrueColor env)
      mkVty' = mkVty defaultConfig
  vty <- mkVty'
  tVty <- getCurrentTime
  logLine (T.pack ("probe vty.ready ms="
                   <> show (round (diffUTCTime tVty tStart * 1000) :: Int)))
  hist <- loadHistory
  stash <- loadStash
  frec <- loadFrecency
  prefs <- loadModelPrefs
  customCmds <- loadCustomCommands
  t0 <- getCurrentTime
  tz0 <- getCurrentTimeZone
  void $ customMain vty mkVty' (Just chan) appFor
        (initialState bridge chan cfg) { appHist = hist, appStash = stash
                                       , appFrecency = frec, appModelPrefs = prefs
                                       , appCustomCmds = customCmds
                                       , appTheme = theme, appNow = Just t0, appTz = Just tz0 }
  tEnd <- getCurrentTime
  logLine (T.pack ("probe brick.exit ms="
                   <> show (round (diffUTCTime tEnd tStart * 1000) :: Int)))

--------------------------------------------------------------------------------
-- Drawing
--------------------------------------------------------------------------------

-- | drawUI / drawToast 见 UI.Brick.Draw.Messages。

-- | Home route: logo, recent sessions, and hints.  Submitting a message (or
-- resuming) moves to the session view (MiMo's home route).
-- | drawHome 见 UI.Brick.Draw.Messages。

-- | The sidebar card: Context, TODO and Session sections.
--
-- The bottom line names the two shortcuts a first-time user needs: hiding
-- the sidebar and leaving the TUI.
-- | drawSidebar 见 UI.Brick.Draw.Sidebar。


-- | Inline slash-command palette, anchored at the input's left edge (the
-- MiMo form: a list above the prompt, filtered as you type — not a centred
-- modal that steals the editor).
-- | drawPalette / drawWizard / wizardSummary 见 UI.Brick.Draw.Dialog。


-- | The @-file popup shown above the input (up to eight candidates).
-- | drawCompletion 见 UI.Brick.Draw.Sidebar。


-- | Display form of the active target: @provider/model@ once a provider is
-- selected, otherwise the bare model name (kernel chooses the provider).
-- | modelLabel 见 UI.Brick.Draw.Status（随状态栏文本层一起迁出）。

-- | sidebarDataFor 见 UI.Brick.Draw.Sidebar。


-- | One dialog as a centered bordered card (the top of the dialog stack).
-- | dialogTitle / dialogSelected / dialogEditable / dialogQuery 见 UI.Dialog。

-- | dialogRow / dialogCountdown / dialogApprovalLabel / dialogConfirmLabel
-- 见 UI.Brick.Draw.Dialog。

-- | 对话框主体行：13 个构造子的分派。
--
-- 窗口位置由本函数自己算（@windowRange n sel 30@），调用方只需给状态与对话框。
-- | dialogRows 见 UI.Brick.Draw.Dialog。


-- | drawDialog 见 UI.Brick.Draw.Dialog。

-- | statusLine 见 UI.Brick.Draw.Status。

-- | Resume a local session: replay its transcript into the message area
-- and make it the active session.
-- | 调度层的压缩标记（govern 写入的一条 user 消息）。
-- | 压缩标记判定见 UI.Render.Spans.isCompactionMark。

-- | resumeSession 见 UI.Brick.SessionView。

-- | setWindowTitle 见 UI.Brick.MessageOps。

-- | pricesOf 见 UI.Brick.Draw.Status。

-- | applyLanguage / applyTheme 见 UI.Brick.Apply。

-- | Numbered listing of local sessions (mirrors the REPL format).
-- | localSessionLines 见 UI.Brick.SessionView。

-- | Turn replay blocks into chat messages for the message area.
-- | blocksToMessages 见 UI.Brick.SessionView。

-- | drawMessages 见 UI.Brick.Draw.Messages。

-- | Whether a finished tool message is omitted from the stream (M6-7).
-- Low-noise lookups vanish once complete, but an explicitly expanded card
-- (the user asked to see it) and @/verbose@ both keep it.
-- | cardHidden / roleStyle / messageHeader 见 UI.Brick.Draw.Messages。

-- | Body of a message: a tool-invocation card, an assistant reply run
-- through the Markdown renderer, or plain wrapped text.
-- | messageBody / renderToolBody 见 UI.Brick.Draw.Messages。

-- | drawMessage 见 UI.Brick.Draw.Messages。

-- | Render a parsed Markdown document as widgets.
-- Paragraph spans re-wrap at the context width with styling preserved
-- (see 'spanWrap'); fenced code blocks get a bordered card labelled with
-- their language; headings and list items render on one line.
-- | renderBlocks 见 UI.Brick.Draw.Messages。

-- | Word-wrap a paragraph of styled inline spans at the available width,
-- preserving each span's attribute on every wrapped line.
--
-- brick 3.0 removed the widget-level 'wrap'; this mirrors the render-time
-- reflow technique of 'txtWrapWith' (measure against the context width,
-- then emit re-flowed images) but re-flows attributed fragments instead
-- of plain text.
-- | spanWrap 见 UI.Brick.Draw.Messages。

-- | Render a diff-shaped tool output: line numbers appear once the terminal
-- is wide enough, and each line keeps its add/remove/hunk colour.
-- | diffWidget 见 UI.Brick.Draw.Messages。

-- | SpanTok / spanToks / fillLines / splitAtWidth / truncLine / diffAttrOf 等
-- 纯函数已抽到 UI.Render.Spans（见该模块），这里只保留渲染与交互。

-- | Greedy word fill 见 UI.Render.Spans.fillLines。

-- | Split the longest prefix whose display width fits @w@ columns.
-- 实现见 UI.Render.Spans.splitAtWidth。

-- | drawPending 见 UI.Brick.Draw.Messages。

-- | drawInput 见 UI.Brick.Draw.Messages。

-- | Braille spinner frames 见 UI.Render.Spans.spinnerFrame。

-- | Live multi-step plan card: the kernel owns the plan, this only renders it.
--
-- Marks: @[x]@ done, @[!]@ failed, @[-]@ skipped, @[+]@ approved (out with the
-- host), @[·]@ pending. The pending step is the one a decision applies to.
-- | drawPlanCard 见 UI.Brick.Draw.Messages。

-- | 状态栏的纯文本源（statusSandboxTag / statusClock / statusModelLine /
-- statusGitLine / statusPeak / statusStatsLine …）已整体迁到
-- UI.Brick.Draw.Status。本模块只保留 Widget 装配。

-- | 统计工具（statusCommas / statusShortK / statusPct / statusOneDec /
-- statusUsable / statusCtxPct / statusTurnsSuffix）见 UI.Brick.Draw.Status。

-- | 状态栏第 2 行的统计段：缓存 / 上下文 / 压缩 / 吞吐 / token / 成本 / 余额 / 峰谷。
--
-- 段的选择与顺序由 @metrics@ 配置决定，但**配置只决定顺序**：未列出的段仍然
-- 显示。历史坑：配置早于新键的用户只看到三段，就以为其余段坏了。
-- | 统计行（statusStatsLine）与全部 segment 已迁到 UI.Brick.Draw.Status。

-- | drawStatus 见 UI.Brick.Draw.Status。

--------------------------------------------------------------------------------
-- Event handling
--------------------------------------------------------------------------------

-- | now / appendMsg 见 UI.Brick.MessageOps。

-- | msgIndexAt / msgHeight 见 UI.Brick.Selection。

-- | inSel / drawMessages 见 UI.Brick.Draw.Messages。

-- | msgRowAt / beginSel / extendSel / copySelectionText / finishSel 见 UI.Brick.Selection。

-- | scrollBottom 见 UI.Brick.DialogKeys。

-- | handleEvent 见 UI.Brick.KeyDispatch。

-- | renderToolEvent 见 UI.Brick.AppEvent。

-- | gitBranchText / gitStatText 见 UI.Brick.Draw.Status。

-- | copyToClipboard 见 UI.Brick.Selection。

-- | 输入操作组见 UI.Brick.InputOps。
