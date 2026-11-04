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
    , groupKey, groupTitle, registryHelp )
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
import UI.Brick.Draw.Settings (drawSettingsPanel, settingsListMax, settingsRows, visibleRows)
import UI.Brick.Draw.Sidebar (drawCompletion, drawSidebar, sidebarDataFor)
import UI.Brick.Draw.Status
  ( modelLabel, pricesOf, statusLine
  , statusSandboxTag, statusClock, statusModelLine, statusGitLine, statusStatsLine )
import UI.Render.Footer (FooterLive(..), footerMetrics, parseMetrics, branchFromHead, statusFitsOneRow, wrapStatusLine)
import UI.Render.Spans
  ( SpanTok(..), boolText, diffAttrOf, fillLines, isCompactionMark
  , spanToks, splitAtWidth, spinnerFrame, truncLine )
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

drawUI :: AppState -> [Widget ResourceName]
drawUI st =
  case appSettings st of
    -- /settings takes over the whole screen (qwen-style dialog): the tab
    -- bar sits at the top and the content fills the terminal.
    Just _  -> [ drawSettingsPanel st ]
    Nothing -> dialogLayer ++ [ overlayLayer, mainUI ]
  where
    -- The sidebar needs the terminal width, which only exists inside a
    -- rendering context.  Dock: share the row.  Overlay: draw the card in a
    -- separate layer translated to the right edge (the cells it does not
    -- cover stay transparent, so the conversation shows through).
    mainUI = Widget Greedy Greedy $ do
      c <- getContext
      let w = c ^. availWidthL
      case sidebarRender w (appSidebar st) of
        RenderDocked sw -> render $ vBox
          [ hBox
              [ hLimit (messageWidth w (appSidebar st)) content
              , padLeft (Pad 1) (drawSidebar st sw)
              ]
          , drawStatus st
          ]
        _ -> render (vBox [content, drawStatus st])

    overlayLayer = Widget Greedy Greedy $ do
      c <- getContext
      let w = c ^. availWidthL
      case sidebarRender w (appSidebar st) of
        RenderOverlay sw -> do
          res <- render (drawSidebar st sw)
          return $ res & imageL %~ V.translate (max 0 (w - sw)) 0
        _ -> return emptyResult

    content = vBox $
      case appRoute st of
        RouteHome ->
          [ maybe emptyWidget drawToast (appToast st)
          , drawHome st
          , drawInput st
          ]
        RouteSession ->
          [ maybe emptyWidget drawToast (appToast st)
          , drawMessages st
          , maybe emptyWidget drawPlanCard (appPlan st)
          , maybe emptyWidget drawWizard (appWizard st)
          , maybe emptyWidget (drawCompletion st) (appComp st)
          , drawInput st
          ]
    -- Brick's draw returns a layer stack: the first widget is the top
    -- layer, so an open dialog renders over the chat as a centered card
    -- (mouse clicks no longer pass through it in brick 3.0).
    dialogLayer = case stackTop (appDialogs st) of
      Just d  -> [ centerLayer (drawDialog st d) ]
      Nothing -> case appPalette st of
        -- Identical attribute to the skills dialog (which the user confirmed
        -- floats correctly): centerLayer is brick's float — transparent
        -- background, no container row taken.
        Just d  -> [ centerLayer (drawPalette d) ]
        Nothing -> []

-- | Transient notice strip above the message area (Toast).
drawToast :: (Text, UTCTime) -> Widget ResourceName
drawToast (msg, _) =
  padLeftRight 1 $
    withAttr (attrName "busy") $
      borderWithLabel (withAttr (attrName "busy") $ str " notice ") $
        padLeftRight 1 $ strWrap (T.unpack msg)

-- | Home route: logo, recent sessions, and hints.  Submitting a message (or
-- resuming) moves to the session view (MiMo's home route).
drawHome :: AppState -> Widget ResourceName
drawHome st =
  padAll 1 $
    vBox $
      [ withAttr (attrName "title") $ vBox (map str logoLines)
      , padTop (Pad 1) $ withAttr (attrName "system") $
          strWrap (T.unpack (tr (appLang st) "Type a message to start a new session, or /resume to continue one."))
      , padTop (Pad 1) $ withAttr (attrName "header") $
          str (T.unpack (tr (appLang st) "Recent sessions"))
      ]
      ++ recentLines
      ++ [ padTop (Pad 1) $ withAttr (attrName "timestamp") $
             strWrap (T.unpack (tr (appLang st) "Shift+Tab switches the permission posture; /help lists commands.")) ]
  where
    recentLines = case take 6 (appRecent st) of
      [] -> [ padLeft (Pad 2) $ withAttr (attrName "timestamp") $
                str (T.unpack (tr (appLang st) "No local sessions yet.")) ]
      xs -> [ padLeft (Pad 2) $
                hBox [ withAttr (attrName "user") (str ("• " ++ T.unpack (ssTitle s)))
                     , withAttr (attrName "timestamp") (str ("  " ++ ssId s)) ]
            | s <- xs ]
    logoLines =
      [ "  ████████╗██████╗ ██╗  ██╗ █████╗ "
      , "  ╚══██╔══╝██╔══██╗██║  ██║██╔══██╗"
      , "     ██║   ██████╔╝███████║███████║"
      , "     ██║   ██╔══██╗██╔══██║██╔══██║"
      , "     ██║   ██║  ██║██║  ██║██║  ██║"
      , "     ╚═╝   ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝"
      ]

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

resumeSession :: Text -> EventM ResourceName AppState ()
resumeSession selText = do
  lang <- gets appLang
  t <- liftIO now
  cwd <- liftIO getCurrentDirectory
  -- `--all` is the escape hatch for transcripts written before sessions
  -- recorded their cwd: they are invisible to the per-project list but still
  -- resumable when asked for explicitly.
  let wantAll = T.strip selText == "--all"
  bridge0 <- gets appBridge
  -- 候选 = 本地 transcript ∪ 调度层（stateDir 恢复的）会话：只存在于
  -- 调度层的会话没有本地 transcript，但历史仍可拉回来继续。
  local <- liftIO (if wantAll then listLocalSessions else resumeSessions bridge0)
  case pickLocalSession (T.unpack selText) local of
    Nothing -> do
      let recent = take 5 local
          listing = T.intercalate ", " (map (T.pack . ssId) recent)
          hint
            | null local = tr lang "No local sessions yet. Run a conversation first."
            | otherwise  = tr lang "Recent sessions: " <> listing
      appendMsg (mkMsg "error"
        (tr lang "No local session matches: " <> selText <> "\n" <> hint) t)
      showToast (tr lang "No matching session")
    Just s -> do
      liftIO $ setWindowTitle ("trha · " <> T.take 8 (T.pack (ssId s)))
      events <- liftIO (loadTranscript (ssId s))
      let localMsgs = blocksToMessages (renderReplay events)
      -- 本地没有 transcript 时从调度层拉历史（stateDir 恢复的会话）。
      remote <- if null localMsgs
        then liftIO (resumeMessages bridge0 (ssId s))
        else pure []
      let msgs = if null localMsgs
                   then [ mkMsg role content t | (role, content) <- remote ]
                   else localMsgs
      modify $ \st -> st { appMessages = msgs
                         , appNextMsgId = length msgs
                         , appCardFocus = Nothing
                         , appSessionId = Just (ssId s)
                         , appStatus = tr (appLang st) "Resumed " <> T.pack (ssId s)
                         , appBusy = False
                         , appPending = Nothing
                         , appRoute = RouteSession
                         -- Cache totals are per session: carrying them across a
                         -- switch silently blends two sessions' hit rates.
                         , appCacheNow = Nothing
                         , appCacheSum = (0, 0)
                         , appCacheTurns = 0
                         , appLastCost = 0
                         , appSessTokens = 0
                         , appLastDecodeTps = Nothing
                         , appFirstToken = Nothing }
      when (null msgs) $
        appendMsg (mkMsg "system" (tr lang "Session " <> T.pack (ssId s) <> tr lang " has an empty transcript.") t)
      -- 调度层会从 stateDir 恢复会话：先问一句它是否真的在，再决定提示。
      bridge0 <- gets appBridge
      live <- liftIO (fetchSessionInfo bridge0 (ssId s))
      appendMsg (mkMsg "system"
        (case live of
           Right _ -> tr lang "This session is live on the scheduler — keep going."
           Left _  -> tr lang "This session is not live on the scheduler; /new starts a fresh one.") t)
      -- 压缩发生在调度层，本地 transcript 里没有那条标记：恢复时把它
      -- 单独显示出来，否则用户看到的是一段"凭空变短"的历史。
      remoteAll <- liftIO (resumeMessages bridge0 (ssId s))
      case [ c | (_, c) <- remoteAll, isCompactionMark c ] of
        (c : _) -> appendMsg (mkMsg "compact" c t)
        []      -> pure ()
      st <- get
      void $ liftIO $ async $
        refreshSidebar (appBridge st) (appChan st) (ssId s)
      scrollBottom

-- | OSC 0: set the terminal window title ("session + busy" per MiMo).setWindowTitle :: Text -> IO ()
setWindowTitle t = do
  hPutStr stdout ("\ESC]0;" <> T.unpack t <> "\BEL")
  hFlush stdout

-- | pricesOf 见 UI.Brick.Draw.Status。

-- | Apply a named theme (switch at runtime + persist in settings).
applyLanguage :: Lang -> EventM ResourceName AppState ()
applyLanguage l = do
  st <- get
  let cfg' = (appEffCfg st) { configLang = langName l }
  liftIO $ saveConfig cfg'
  modify $ \s -> s { appLang = l, appEffCfg = cfg'
                   , appDialogs = stackPop (appDialogs s)
                   , appStatus = tr l "Language: " <> langName l }

applyTheme :: Text -> EventM ResourceName AppState ()
applyTheme name = do
  st2 <- get
  let th = resolveTheme name
  if T.toLower (themeName th) /= T.toLower name
    then showToast ("Unknown theme: " <> name)
    else do
      let cfg' = (appEffCfg st2) { configTheme = themeName th }
      liftIO $ saveConfig cfg'
      modify $ \s -> s { appTheme = th, appEffCfg = cfg' }
      showToast ("Theme: " <> themeName th)

-- | Numbered listing of local sessions (mirrors the REPL format).
localSessionLines :: Lang -> [SessionSummary] -> [Text]
localSessionLines lang sessions =
  [ "  [" <> T.pack (show (i :: Int)) <> "] " <> ssTitle s
      <> "  (" <> T.pack (ssId s)
      <> maybe "" (\m -> " · " <> m) (ssModel s)
      <> " · " <> T.pack (show (ssTurns s)) <> tr lang " turn(s)"
      <> maybe "" (\tok -> " · " <> T.pack (show tok) <> " tok") (ssUsage s)
      <> maybe "" (\ts -> " · " <> ts) (ssLastTs s)
      <> ")"
  | (i, s) <- zip [1 :: Int ..] sessions ]

-- | Turn replay blocks into chat messages for the message area.
blocksToMessages :: [ReplayBlock] -> [ChatMessage]
blocksToMessages blocks =
  zipWith (\i m -> m { msgId = i }) [0 ..] (map toMsg blocks)
  where
    toMsg b = case rbTool b of
      Just (name, args) ->
        toolMsg "tool" (ToolCard name args Nothing Nothing [] "") (maybe "" id (rbTime b))
      Nothing           -> mkMsg (rbRole b) (rbContent b) (maybe "" id (rbTime b))

drawMessages :: AppState -> Widget ResourceName
drawMessages st =
  withAttr (attrName "border") $
    borderWithLabel (withAttr (attrName "title") $ str " trha — agent harness · Messages ") $
      viewport MessageArea Vertical $
        vBox $
          case (appMessages st, visible, appPending st) of
            ([], _, Nothing) ->
              [ padAll 1 $ withAttr (attrName "timestamp") $
                  strWrap "No messages yet. Type something and press Enter, or /help for commands." ]
            (_, [], Nothing) ->
              -- Everything on screen was a quiet tool card (M6-7); say so
              -- instead of drawing an empty viewport.
              [ padAll 1 $ withAttr (attrName "timestamp") $
                  strWrap "All tool cards are hidden (quiet read/search). /verbose shows them." ]
            _ -> [ let -- 焦点标记只属于工具卡：之前只看 id 相等，焦点落到
                       -- 同号的 user 消息上时，「▶」会画在用户消息前面。
                       focused = isJust (msgTool m) && appCardFocus st == Just (msgId m)
                       fold = foldOf m
                       sel = inSel st (msgId m)
                       draw = drawMessage cfg focused fold m
                       widget = if sel then withAttr (attrName "selection") draw else draw
                   -- Retained per-message render (the ported TranscriptScrolling
                   -- contract): scrolling and typing redraw only what changed.
                   in cached (MsgCache (msgId m) (fold == FoldExpanded) focused sel) widget
                 | m <- visible ]
                   ++ maybe [] (pure . drawPending cfg) (appPending st)
  where
    cfg = appEffCfg st
    visible = filter (not . cardHidden st) (appMessages st)
    foldOf m
      | appVerbose st = FoldExpanded
      | otherwise = fromMaybe FoldCollapsed (Map.lookup (msgId m) (appFolds st))

-- | Whether a finished tool message is omitted from the stream (M6-7).
-- Low-noise lookups vanish once complete, but an explicitly expanded card
-- (the user asked to see it) and @/verbose@ both keep it.
cardHidden :: AppState -> ChatMessage -> Bool
cardHidden st m
  | appVerbose st = False
  | Map.lookup (msgId m) (appFolds st) == Just FoldExpanded = False
  | otherwise = maybe False shouldHideTool (msgTool m)

-- | Display style for a message role: (attribute, bracket label).  Errors are
-- classified so a rate limit reads as such instead of a generic failure
-- (MiMo's @errorKind()@).
roleStyle :: Text -> Text -> (AttrName, Text)
roleStyle role content = case role of
  "user"      -> (attrName "user", role)
  "assistant" -> (attrName "assistant", role)
  "tool"      -> (attrName "tool", role)
  "plan"      -> (attrName "plan", role)
  "system"    -> (attrName "system", role)
  "error"     -> (attrName "error", errorLabel (classifyError content))
  "thinking"  -> (attrName "system", "thinking")
  "step"      -> (attrName "timestamp", "step")
  "stats"     -> (attrName "timestamp", "stats")
  "compact"   -> (attrName "plan", "context")
  "retry"     -> (attrName "busy", "retry")
  "shell"     -> (attrName "tool", "shell")
  _           -> (attrName "header", role)

-- | Header row shared by messages and the streaming block:
-- @[role] timestamp@.
messageHeader :: Bool -> Text -> Text -> Text -> Widget ResourceName
messageHeader showTs role content time
  -- The per-turn accounting line is a plain row, not a bracketed message.
  | role == "stats" = emptyWidget
  | otherwise = hBox (roleW : [timeW | showTs])
  where
    sty = roleStyle role content
    roleW = withAttr (fst sty) $ str $ "[" ++ T.unpack (snd sty) ++ "]"
    timeW = hBox [str " ", withAttr (attrName "timestamp") (str (T.unpack time))]

-- | Body of a message: a tool-invocation card, an assistant reply run
-- through the Markdown renderer, or plain wrapped text.
messageBody :: Bool -> Text -> Text -> Maybe ToolCard -> ToolFold -> Widget ResourceName
messageBody md role content tool fold
  | role == "stats" =
      padLeft (Pad 2) $ withAttr (attrName "timestamp") $ strWrap (T.unpack content)
  | otherwise =
      case tool of
    Just card -> renderToolBody card fold

    Nothing
      | role == "assistant" && md ->
          padLeft (Pad 2) $
            withAttr (attrName "assistant") $
              vBox (renderBlocks (parseMarkdown content))
      | role == "assistant" ->
          padLeft (Pad 2) $
            withAttr (attrName "assistant") $ strWrap (T.unpack content)
      | role == "error" ->
          padLeft (Pad 2) $
            vBox $
              [ strWrap (T.unpack content) ]
                ++ [ withAttr (attrName "status") (strWrap (T.unpack hint))
                   | Just hint <- [errorHint (classifyError content)] ]
      | role == "thinking" ->
          -- Reasoning is long; show the first lines plus a size hint (MiMo
          -- folds it behind "Thought for Xs").
          padLeft (Pad 2) $
            withAttr (attrName "system") $
              borderWithLabel (withAttr (attrName "system") $ str " thinking ") $
                vBox $
                  [ padLeftRight 1 $ strWrap (T.unpack l)
                  | l <- take 3 (filter (not . T.null) (T.lines content)) ]
                    ++ [ padLeftRight 1 $ withAttr (attrName "timestamp") $
                           str ("… (" <> show (T.length content) <> " chars)") ]
      | role == "step" ->
          padLeft (Pad 2) $
            withAttr (attrName "timestamp") $
              str ("── " <> T.unpack content <> " ──")
      | role == "compact" ->
          padLeft (Pad 2) $
            withAttr (attrName "plan") $
              borderWithLabel (withAttr (attrName "plan") $ str " context ") $
                padLeftRight 1 (strWrap (T.unpack content))
      | role == "retry" ->
          padLeft (Pad 2) $ withAttr (attrName "busy") $ strWrap (T.unpack content)
      | role == "shell" ->
          padLeft (Pad 2) $ withAttr (attrName "system") $ strWrap (T.unpack content)
      | role == "plan" ->
          -- plan/approval card (Reasonix plan-decision style)
          padLeft (Pad 2) $
            withAttr (attrName "plan") $
              borderWithLabel (withAttr (attrName "plan") $ str " Plan ") $
                vBox
                  [ padLeftRight 1 $ strWrap (T.unpack content)
                  , padLeftRight 1 $ withAttr (attrName "status") $
                      str "run /approve or /deny"
                  ]
      | otherwise ->
          case filePartsOf content of
            [] -> padLeft (Pad 2) $ strWrap (T.unpack content)
            refs ->
              -- Attachment tokens became file parts (M5-7): the prose keeps
              -- wrapping, each path gets its own row.
              let prose = stripFileTokens content
              in padLeft (Pad 2) $ vBox $
                   [ strWrap (T.unpack prose) | not (T.null prose) ]
                     ++ [ withAttr (attrName "timestamp") (str (T.unpack (filePartLine r)))
                        | r <- refs ]

-- | One tool card.  Collapsed: a family-specific headline (shell command,
-- path, pattern, task…).  Expanded: family detail lines, then the diff or
-- output preview.  @present@ renders as a card and skips the raw payload.
renderToolBody :: ToolCard -> ToolFold -> Widget ResourceName
renderToolBody card fold =
  padLeft (Pad 2) $ withAttr (attrName "tool") $
    case fold of
      FoldCollapsed -> str (T.unpack (toolHeadline card))
      FoldExpanded ->
        vBox $
          [ str (T.unpack l) | l <- toolDetailLines card ]
            ++ outputWidgets
            ++ [ withAttr (attrName "status") $ str (T.unpack (toolStatusLine st (tcDur card)))
               | Just st <- [tcStatus card] ]
  where
    outputWidgets
      | isJust (presentCard card) = []
      | looksLikeDiff (tcOutput card) = [diffWidget (tcOutput card)]
      | otherwise =
          [ withAttr (diffAttrOf (diffClass l)) $
              str (T.unpack ("  │ " <> truncLine l))
          | l <- tcOutput card ]

drawMessage :: CLIConfig -> Bool -> ToolFold -> ChatMessage -> Widget ResourceName
drawMessage cfg focused fold msg
  | msgRole msg == "thinking" =
      padLeftRight 1 $ vBox $
        [ hBox
            [ clickable (ThinkToggle (msgId msg)) $
                withAttr (attrName "system")
                  (str (if fold == FoldCollapsed then "▸ " else "▾ "))
            , withAttr (attrName "system")
                (str (T.unpack (fromMaybe "思考 (Ctrl+O)" (msgMeta msg))))
            ]
        ] ++ [ padLeft (Pad 2) $ withAttr (attrName "system")
                 $ strWrap (T.unpack (msgContent msg))
             | fold == FoldExpanded ]
  | otherwise =
  padLeftRight 1 $
    padTopBottom 1 $
      vBox $
        [ hBox
            [ if focused then withAttr (attrName "selection") (str "▶ ") else emptyWidget
            , messageHeader (configTimestamps cfg) (msgRole msg) (msgContent msg) (msgTime msg) ]
        , messageBody (configMarkdown cfg) (msgRole msg) (msgContent msg) (msgTool msg) fold
        ]
          ++ [ padLeft (Pad 2) $ withAttr (attrName "timestamp") (str (T.unpack m))
             | Just m <- [msgMeta msg] ]

-- | Render a parsed Markdown document as widgets.
-- Paragraph spans re-wrap at the context width with styling preserved
-- (see 'spanWrap'); fenced code blocks get a bordered card labelled with
-- their language; headings and list items render on one line.
renderBlocks :: [MdBlock] -> [Widget ResourceName]
renderBlocks = map renderBlock
  where
    renderBlock (MdCodeBlock lang code) =
      padTop (Pad 1) $
        withAttr (attrName "codeBlock") $
          borderWithLabel (withAttr (attrName "codeLang") $ str (" " ++ T.unpack lang ++ " ")) $
            vBox [ strWrap (T.unpack l) | l <- T.lines code ]
    renderBlock (MdParagraph spans) = spanWrap spans
    renderBlock (MdHeading level spans) =
      padTop (if level <= 2 then Pad 1 else Pad 0) $
        withAttr (attrName "header") $
          str (T.unpack (T.replicate level "#" <> " ")) <+> spanLine spans
    renderBlock (MdListItem marker spans) =
      padLeft (Pad 2) $ str (T.unpack marker <> " ") <+> spanLine spans

    -- markers are stripped; the styling lives in the attribute
    spanWidget (MdPlain t) = str (T.unpack t)
    spanWidget (MdBold t)  = withAttr (attrName "mdBold") $ str (T.unpack t)
    spanWidget (MdCode t)  = withAttr (attrName "mdCode") $ str (T.unpack t)
    spanLine spans = hBox (map spanWidget spans)

-- | Word-wrap a paragraph of styled inline spans at the available width,
-- preserving each span's attribute on every wrapped line.
--
-- brick 3.0 removed the widget-level 'wrap'; this mirrors the render-time
-- reflow technique of 'txtWrapWith' (measure against the context width,
-- then emit re-flowed images) but re-flows attributed fragments instead
-- of plain text.
spanWrap :: [MdSpan] -> Widget ResourceName
spanWrap spans = Widget Greedy Fixed $ do
  c <- getContext
  let width = max 1 (c ^. availWidthL)
      resolve n = attrMapLookup (attrName n) (c ^. ctxAttrMapL)
      imgs =
        [ V.horizCat [ V.text' (resolve (tokAttr t)) (tokText t) | t <- ts ]
        | ts <- fillLines width (concatMap spanToks spans)
        ]
  return $ emptyResult & imageL .~ V.vertCat imgs

-- | Render a diff-shaped tool output: line numbers appear once the terminal
-- is wide enough, and each line keeps its add/remove/hunk colour.
diffWidget :: [Text] -> Widget ResourceName
diffWidget ls = Widget Greedy Fixed $ do
  c <- getContext
  let width = max 1 (c ^. availWidthL)
      lay = diffLayout width
      resolve n = attrMapLookup n (c ^. ctxAttrMapL)
      prefix = case lay of
        DiffInline   -> "  │ "
        DiffNumbered -> ""
      rows = [ r { drText = truncLine (drText r) } | r <- numberDiff ls ]
      imgs = [ V.text' (resolve (diffAttrOf (drClass r)))
                   (prefix <> renderDiffRow lay r)
             | r <- rows ]
  return $ emptyResult & imageL .~ V.vertCat imgs

-- | SpanTok / spanToks / fillLines / splitAtWidth / truncLine / diffAttrOf 等
-- 纯函数已抽到 UI.Render.Spans（见该模块），这里只保留渲染与交互。

-- | Greedy word fill 见 UI.Render.Spans.fillLines。

-- | Split the longest prefix whose display width fits @w@ columns.
-- 实现见 UI.Render.Spans.splitAtWidth。

-- | Render the assistant reply currently being accumulated.
-- A blinking cursor suffix signals that the stream is still open.
drawPending :: CLIConfig -> PendingMsg -> Widget ResourceName
drawPending cfg pm =
  padLeftRight 1 $
    padTopBottom 1 $
      vBox
        [ messageHeader (configTimestamps cfg) "assistant" (pmContent pm) (pmStart pm)
        , messageBody (configMarkdown cfg) "assistant" (pmContent pm <> "▍") Nothing FoldCollapsed
        ]

drawInput :: AppState -> Widget ResourceName
drawInput st =
  withAttr (attrName "border") $
    borderWithLabel busyLabel $
      withAttr (attrName "input") $
        -- One row: this is a text input, not a multi-line editor (the user
        -- asked for minHeight=1; shortcuts live on Ctrl+… only).
        vLimit 1 $
          renderEditor (str . T.unpack . T.unlines) True (appInput st)
  where
    visibleRows = max 1 (min 6 (length (getEditContents (appInput st))))
    -- No timer thread: streaming deltas drive redraws, so the frame index
    -- derives from the accumulated length — it animates exactly while the
    -- reply is actually moving (a frozen spinner honestly shows a stall).
    awaitingStep = isJust (appApproval st)
                   || case appPlan st of
                        Just pv -> isJust (pvPending pv)
                        Nothing -> False
    busyLabel = case runState (appBusy st) awaitingStep of
      RunIdle -> str " Input "
      RunAwaiting ->
        withAttr (attrName "plan") $ str " ⏸ Awaiting approval… "
      RunRunning ->
        withAttr (attrName "busy") $ str $
          case appPending st of
            Just pm -> " " <> T.unpack (spinnerFrame (T.length (pmContent pm))) <> " Streaming… "
            Nothing -> " ⏳ Thinking… "

-- | Braille spinner frames 见 UI.Render.Spans.spinnerFrame。

-- | Live multi-step plan card: the kernel owns the plan, this only renders it.
--
-- Marks: @[x]@ done, @[!]@ failed, @[-]@ skipped, @[+]@ approved (out with the
-- host), @[·]@ pending. The pending step is the one a decision applies to.
drawPlanCard :: PlanView -> Widget ResourceName
drawPlanCard pv =
  withAttr (attrName "plan") $
    borderWithLabel (withAttr (attrName "plan") $ str " Plan ") $
      vBox $
        [ padLeftRight 1 $ withAttr (attrName "status") $
            str (T.unpack (phaseLabel (pvPhase pv)))
        ]
        ++ zipWith (\n st -> padLeftRight 1 . str . T.unpack $ renderStep pv (n, st))
                   [1 :: Int ..] (pvSteps pv)
        ++ [ padLeftRight 1 $ withAttr (attrName "status") $ str (T.unpack hints)
           | not (T.null hints) ]
  where
    phaseLabel "executing_step" = "running a step…"
    phaseLabel "planning"       = "waiting for a decision"
    phaseLabel other            = other
    hints :: Text
    hints
      | pvPhase pv == "planning" = "/approve · /skip · /reject · /abandon"
      | otherwise                = "/abandon"
    renderStep p (n, st) =
      let mark = case psvStatus st of
            "done"     -> "[x]"
            "failed"   -> "[!]"
            "skipped"  -> "[-]"
            "approved" -> "[+]"
            "rejected" -> "[r]"
            _          -> "[·]"
          here = if pvPending pv == Just (psvId st) then "  ←" else ""
      in T.pack (show (n :: Int)) <> ". " <> mark <> " " <> psvTitle st <> here

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

drawStatus :: AppState -> Widget ResourceName
drawStatus st = Widget Greedy Fixed $ do
  c <- getContext
  render (vBox (line1 (c ^. availWidthL) : secondRow (c ^. availWidthL)))
  where
    lang = appLang st
    -- 窄终端先牺牲常驻帮助文本：模型名与沙箱徽标比「Shift+Tab …」这类
    -- 看过就会的提示更值得占位（80 列下实测模型名会被整段挤掉）。
    line1 avail = padLeftRight 1 $ hBox (concat
      [ [ withAttr (attrName "error") (str (T.unpack modeTag))
        -- 这里原来是常量 " · ready"：appStatus 被各处设置（工具状态、
        -- 中断中、再按一次退出…）却从未真正显示出来。
        , withAttr (attrName "status")
            (str (T.unpack (" · " <> takeCells 48 (appStatus st))))
        ]
      , [ withAttr (attrName "timestamp") (str (T.unpack (" · " <> clockNow)))
        | not (T.null clockNow) ]
      , if avail >= 130
          then [ withAttr (attrName "timestamp")
                   (str (T.unpack (tr lang " · Shift+Tab read-only/ask/auto/YOLO/plan · Ctrl+Y YOLO")))
               , str "   "
               , withAttr (attrName (if ssEnabled (appSandbox st) then "status" else "error"))
                   (str (T.unpack sandboxTag)) ]
          else []
      , [ padLeft Max (withAttr (attrName "timestamp") (str (T.unpack modelLine))) ]
      ])
    line2 = padLeftRight 1 $ hBox
      [ withAttr (attrName "timestamp") (str (T.unpack gitLine))
      , padLeft Max (withAttr (attrName "timestamp") (str (T.unpack statsLine)))
      ]
    -- Second row: git summary on the left, metrics on the right.  Only when
    -- the two fit side by side — otherwise hBox clips the right end of the
    -- metrics (balance / cost / peak) with no way to read it.  On a narrow
    -- terminal each side gets its own rows, wrapped by display width.
    secondRow avail
      | statusFitsOneRow budget gitLine statsLine = [line2]
      | otherwise = map row (wrapStatusLine budget gitLine ++ wrapStatusLine budget statsLine)
      where
        budget = max 1 (avail - 2)
        row r = padLeftRight 1 $ timestampWidget $ str (T.unpack r)
    timestampWidget = withAttr (attrName "timestamp")
    modeTag = maybe "Read only" smLabel (appMode st)
    sandboxTag = statusSandboxTag st
    clockNow = statusClock st
    modelLine = statusModelLine st
    gitLine = statusGitLine st
    -- 统计段的实现在顶层 statusStatsLine（本批次迁出），此处不再保留副本。
    -- （成本 / 余额 / 缓存命中段同样在 statusStatsLine 里）
    statsLine = statusStatsLine st

--------------------------------------------------------------------------------
-- Event handling
--------------------------------------------------------------------------------

now :: IO Text
now = do
  t <- getCurrentTime
  tz <- getCurrentTimeZone
  pure (clockWithZone tz t)

-- | Append a message, stamping it with the next position-based id.
appendMsg :: ChatMessage -> EventM ResourceName AppState ()
appendMsg msg = modify $ \st ->
  let i = appNextMsgId st
  in st { appMessages = appMessages st ++ [msg { msgId = i }]
        , appNextMsgId = i + 1 }

-- | Message under a screen row (approximate: content lines + 2).
msgIndexAt :: Int -> AppState -> Maybe Int
msgIndexAt y st =
  let hs = [ msgHeight st m | m <- appMessages st ]
      tops = scanl (+) 0 hs
  in listToMaybe [ i | i <- [0 .. length hs - 1], y >= tops !! i, y < tops !! (i + 1) ]

-- | Screen rows a message occupies (a folded reasoning block is one line).
msgHeight :: AppState -> ChatMessage -> Int
msgHeight st m
  | msgRole m == "thinking"
  , Map.lookup (msgId m) (appFolds st) /= Just FoldExpanded = 1
  | otherwise = max 1 (length (T.lines (msgContent m))) + 2

inSel :: AppState -> Int -> Bool
inSel st i = case appSelStart st of
  Nothing -> False
  Just a  -> let b = fromMaybe a (appSelEnd st) in i >= min a b && i <= max a b

-- | A terminal row → the message area's row: the box border + title take two
-- rows, and the viewport may be scrolled.  Without this every click landed on
-- the wrong message, so the thinking triangle never toggled.
msgRowAt :: Int -> EventM ResourceName AppState Int
msgRowAt y = do
  st <- get
  -- The message box contributes a border + title (2 rows); a visible toast
  -- adds its own 3-row box above it.
  let toastRows = maybe 0 (const 3) (appToast st)
  pure (max 0 (y - 2 - toastRows))

beginSel :: Int -> EventM ResourceName AppState ()
beginSel y = do
  st <- get
  rel <- msgRowAt y
  let i = fromMaybe 0 (msgIndexAt rel st)
  modify $ \s -> s { appSelStart = Just i, appSelEnd = Just i }

extendSel :: Int -> EventM ResourceName AppState ()
extendSel y = do
  st <- get
  rel <- msgRowAt y
  case appSelStart st of
    Nothing -> return ()
    Just _  -> modify $ \s -> s { appSelEnd = Just (fromMaybe 0 (msgIndexAt rel s)) }

-- | 复制当前选区的文本。@clearSel@ 决定复制后是否清空选区：
-- 鼠标松开时保留高亮（用户还能接着调整，Ctrl+C 才清掉），Ctrl+C 复制后清空。
copySelectionText :: Bool -> EventM ResourceName AppState ()
copySelectionText clearSel = do
  st <- get
  case appSelStart st of
    Nothing -> pure ()
    Just a0 -> do
      let b0 = fromMaybe a0 (appSelEnd st)
          lo = min a0 b0
          hi = max a0 b0
          txt = T.intercalate "\n\n"
                  [ msgContent m | m <- appMessages st, msgId m >= lo, msgId m <= hi ]
      when (not (T.null (T.strip txt))) $ do
        ok <- liftIO (copyToClipboard txt)
        showToast (if ok then "Copied" else "Clipboard unavailable")
      when clearSel $
        modify $ \s -> s { appSelStart = Nothing, appSelEnd = Nothing }

finishSel :: Int -> EventM ResourceName AppState ()
finishSel y = do
  st <- get
  case appSelStart st of
    Nothing -> return ()
    Just a0 -> do
      let b0 = fromMaybe a0 (appSelEnd st)
          lo = min a0 b0
          hi = max a0 b0
          isThinking = any (\m -> msgId m == a0 && msgRole m == "thinking") (appMessages st)
      if a0 == b0 && isThinking
        then modify $ \s -> s
               { appFolds = Map.alter (Just . toggleFold . fromMaybe FoldCollapsed) a0 (appFolds s)
               , appSelStart = Nothing, appSelEnd = Nothing }
        -- 松开鼠标时复制但**保留**选区：高亮还在，Ctrl+C 仍可复制，
        -- 也还能继续拖选调整。清空只发生在 Ctrl+C 之后。
        else copySelectionText False

scrollBottom :: EventM ResourceName AppState ()
scrollBottom = vScrollToEnd (viewportScroll MessageArea)

handleEvent :: BrickEvent ResourceName AppEvent -> EventM ResourceName AppState ()
handleEvent (AppEvent ev) = handleAppEvent ev
-- Shift+Tab is a global posture shortcut: handle it before dialogs/settings/
-- editors so the key can never be swallowed by another handler.
handleEvent (VtyEvent (EvKey KBackTab _)) =
  modeAction (object ["action" .= ("cycle" :: Text)])
handleEvent (VtyEvent (EvKey (KChar '\t') ms))
  | MShift `elem` ms = modeAction (object ["action" .= ("cycle" :: Text)])
handleEvent (VtyEvent (EvKey (KChar 'q') [MCtrl])) = halt
-- Ctrl+Alt+Q is the *service-level* stop (kernel + scheduler), not another
-- shell exit: the kernel is shared by TUI, Desktop and Web and has no "quit"
-- of its own, so stopping it tears down every trha process.  This mirrors
-- Desktop's `Services → Stop kernel and scheduler…` and `/stop confirm`, and
-- opens the confirmation dialog first.  vty delivers Alt as an ESC prefix, so
-- the key arrives as MMeta+MCtrl (MAlt is accepted for parsers that report Alt
-- directly); GNOME Terminal binds Ctrl+Shift+Q to close-window and never
-- forwards it, so this combination is the one that reaches the shell.
handleEvent (VtyEvent (EvKey (KChar 'q') ms))
  | MCtrl `elem` ms && (MMeta `elem` ms || MAlt `elem` ms) = requestStopServices
handleEvent (VtyEvent (EvKey (KChar 'c') [MCtrl])) = handleCtrlCKey
handleEvent (VtyEvent (EvKey (KChar 'd') [MCtrl])) = handleCtrlDKey
handleEvent (VtyEvent (EvKey KEsc _)) = do
  st <- get
  case appSettings st of
    Just _  -> handleSettingsKey (EvKey KEsc [])
    Nothing | isJust (appWizard st) ->
      modify $ \s -> s { appWizard = Nothing
                       , appInput = editorText InputArea (Just 1) ""
                       , appStatus = tr (appLang s) "Ready" }
    Nothing -> case appComp st of
      -- MiMo's hierarchy: the autocomplete popup closes before anything
      -- else, and closing it must not arm the interrupt double-press.
      Just _  -> modify $ \s -> s { appComp = Nothing, appEscLast = Nothing }
      Nothing -> case appPalette st of
        -- Esc dismisses the command palette without touching the input.
        Just _  -> modify $ \s -> s { appPalette = Nothing, appEscLast = Nothing }
        Nothing -> escapeHierarchy
-- Mouse drag selects whole messages (brick exposes no per-cell text map);
-- releasing copies them, so terminal row-copy is not needed.
handleEvent (MouseDown (ThinkToggle i) BLeft _ _) =
  modify $ \s -> s
    { appFolds = Map.alter (Just . toggleFold . fromMaybe FoldCollapsed) i (appFolds s) }
handleEvent (MouseDown _ BScrollUp _ _) =
  vScrollBy (viewportScroll MessageArea) (-3)
handleEvent (MouseDown _ BScrollDown _ _) =
  vScrollBy (viewportScroll MessageArea) 3
-- Drag-select still works through brick's wrapped events: anchor on the first
-- left press, extend on the following ones, copy on release.
handleEvent (MouseDown _ BLeft _ (Location (_, y))) = do
  st <- get
  if isJust (appSelStart st) then extendSel y else beginSel y
handleEvent (MouseUp _ (Just BLeft) (Location (_, y))) = finishSel y
handleEvent (VtyEvent (EvMouseDown _ y BLeft [])) = do
  st <- get
  -- vty reports a drag as repeated mouse-down events; the first one anchors.
  if isJust (appSelStart st) then extendSel y else beginSel y
handleEvent (VtyEvent (EvMouseUp _ y (Just BLeft))) = finishSel y
handleEvent (VtyEvent (EvMouseDown _ _ BScrollUp _)) =
  vScrollBy (viewportScroll MessageArea) (-3)
handleEvent (VtyEvent (EvMouseDown _ _ BScrollDown _)) =
  vScrollBy (viewportScroll MessageArea) 3
-- | 长粘贴折叠：原文存进 appPastes，输入框只放一个占位符
-- （Reasonix 的 @[Pasted text #N · X lines]@）。短粘贴照常进编辑器。
handleEvent (VtyEvent (EvPaste bs)) = do
  let txt = TE.decodeUtf8With TEE.lenientDecode bs
  if isLongPaste txt
    then insertPaste txt
    else do
      editDefaultKey (EvPaste bs)
      refreshCompletion >> refreshPalette

-- A dialog is modal: while one is open the top dialog owns every key and
-- the editor gets nothing until it closes.
handleEvent (VtyEvent ev) = do
  t <- liftIO getCurrentTime
  modify $ \s -> s { appNow = Just t }
  st <- get
  case appSettings st of
    Just _  -> handleSettingsKey ev
    Nothing -> case stackTop (appDialogs st) of
      Just _  -> handleDialogKey ev
      Nothing
        | appLeader st -> handleLeaderKey ev
        | otherwise    -> handleChatKey ev
handleEvent _ = return ()

-- | One keystroke after the leader (ctrl+x).  Executes one action, then
-- disarms; anything unbound cancels.
handleLeaderKey :: Event -> EventM ResourceName AppState ()
handleLeaderKey (EvKey KEsc _) = disarmLeader "Ready"
handleLeaderKey (EvKey (KChar c) []) = do
  modify $ \s -> s { appLeader = False }
  case leaderResolve c of
    Just LeaderSidebar   -> modify $ \s -> s { appSidebar = toggleSidebar (appSidebar s) }
    Just LeaderProvider  -> handleSlash "/provider"
    Just LeaderModels    -> handleSlash "/models"
    Just LeaderSessions  -> handleSlash "/sessions"
    Just LeaderSettings  -> handleSlash "/settings"
    Just LeaderHelp      -> handleSlash "/help"
    Just LeaderInterrupt -> requestInterrupt
    Nothing              -> disarmLeader "Unknown leader key"
handleLeaderKey _ = disarmLeader "Ready"

disarmLeader :: Text -> EventM ResourceName AppState ()
disarmLeader msg = modify $ \s -> s
  { appLeader = False, appStatus = tr (appLang s) msg }

-- | Ctrl+C follows the terminal convention: interrupt first, clear input
-- second, quit only on a second press from an idle empty prompt.  Ctrl+D quits
-- only from an idle empty prompt; Ctrl+Q stays as a direct exit.
handleCtrlCKey :: EventM ResourceName AppState ()
handleCtrlCKey = do
  st <- get
  now <- liftIO getCurrentTime
  -- 有选区时 ctrl+c 先复制（Reasonix 的 copyIt），否则才走中断/清空/退出。
  case appSelStart st of
    Just _  -> copySelectionText True
    Nothing -> case decideCtrlC (appBusy st) (not (promptIsEmpty st)) (appQuitLast st) now of
      CtrlCInterrupt  -> requestInterrupt
      CtrlCClearInput -> modify $ \s -> s { appInput = editorText InputArea (Just 1) "" }
      CtrlCQuit       -> halt
      CtrlCArmQuit    -> modify $ \s -> s
        { appQuitLast = Just now
        , appStatus = tr (appLang s) "Press Ctrl+C again to quit"
        }

handleCtrlDKey :: EventM ResourceName AppState ()
handleCtrlDKey = do
  st <- get
  when (decideCtrlD (appBusy st) (not (promptIsEmpty st))) halt

promptIsEmpty :: AppState -> Bool
promptIsEmpty st = T.null (T.strip (T.unlines (getEditContents (appInput st))))

-- | Ask the host to stop the running turn (shared by the leader and the
-- double-escape path).
requestInterrupt :: EventM ResourceName AppState ()
requestInterrupt = do
  st <- get
  modify $ \s -> s { appStatus = tr (appLang s) "Interrupting..." }
  case appSessionId st of
    Nothing -> return ()
    Just sid -> void $ liftIO $ async $ void (interruptSession (appBridge st) sid)

-- | Ctrl+Alt+Q: the service-level stop.  The kernel and scheduler are shared
-- by every shell, so this needs the same explicit confirmation as @/stop@ —
-- one keystroke must never tear down the backend.  The dialog defaults to
-- "No"; confirming runs 'stopAll' and then leaves the shell.
requestStopServices :: EventM ResourceName AppState ()
requestStopServices = do
  lang <- gets appLang
  modify $ \s -> s
    { appDialogs = stackPush
        (DialogConfirm (tr lang "Stop the kernel and scheduler? Every shell (TUI, Desktop, Web) disconnects.") 1)
        (appDialogs s)
    , appPendingStop = True }

-- | Confirmed service stop: SIGTERM kernel + scheduler, report, then halt.
-- The dialog itself was already popped by 'dialogActivate'.
stopServicesAndHalt :: EventM ResourceName AppState ()
stopServicesAndHalt = do
  modify $ \s -> s { appPendingStop = False
                   , appStatus = tr (appLang s) "Stopping services..." }
  t <- liftIO now
  rs <- liftIO (stopAll False)
  let out = T.intercalate "\n"
              [ T.pack (stopResultText svc r) | (svc, r) <- rs ]
  appendMsg (mkMsg "system" out t)
  halt

-- | Answer the parked ask: post the decision and let EvVerdict close the
-- loop (it clears appApproval and busy).
decideApprovalNow :: Bool -> EventM ResourceName AppState ()
decideApprovalNow approve = do
  st <- get
  modify $ \s -> s { appDialogs = stackPop (appDialogs s)
                   , appStatus = tr (appLang s)
                       (if approve then "Approving..." else "Denying...") }
  case appSessionId st of
    Nothing -> do
      -- nothing to answer: drop the parked state instead of hanging
      modify $ \s -> s { appApproval = Nothing, appBusy = False
                       , appStatus = tr (appLang s) "No session to approve" }
    Just sid -> do
      let bridge = appBridge st
          chan   = appChan st
      void $ liftIO $ async $ do
        r <- decidePlan bridge sid approve
        writeBChan chan (EvVerdict r)

-- | The "always" confirmation card's message.
alwaysConfirmText :: Lang -> String -> [Text] -> Text
alwaysConfirmText lang name args =
  tr lang "Always allow " <> T.pack name
    <> case args of (c : _) -> " " <> T.replace "\n" " " c; [] -> ""
    <> tr lang " for future runs?"

-- | Escape resolution per MiMo's hierarchy.  A parked ask is rejected on
-- escape (permission page escapeKey=reject); otherwise pop an open
-- dialog; a second press within 5 seconds requests an interrupt (the
-- real cancel lands with the approval lock in M3).
escapeHierarchy :: EventM ResourceName AppState ()
escapeHierarchy = do
  approval <- gets appApproval
  case approval of
    Just _  -> decideApprovalNow False
    Nothing -> escapeWithoutApproval
escapeWithoutApproval :: EventM ResourceName AppState ()
escapeWithoutApproval = do
  st <- get
  now <- liftIO getCurrentTime
  let within = maybe False (\t0 -> diffUTCTime now t0 <= 5) (appEscLast st)
      -- Only a turn that is actually running can be interrupted; an idle
      -- press leaves no arm behind (otherwise the next press would fire).
      running = appBusy st && isNothing (appApproval st)
      (fired, keepArmed) = escWiring running within (isJust (appEscLast st))
      arm = if keepArmed then Just now else Nothing
      flags = EscFlags { efSelection = False
                       , efStack = not (stackNull (appDialogs st))
                       , efShell = False
                       , efComplete = isJust (appComp st) }
  case resolveEscape flags of
    EscPopDialog ->
      modify $ \s -> s { appDialogs = stackPop (appDialogs s), appEscLast = Nothing
                       , appPendingStop = False }
    _ | fired -> do
          modify $ \s -> s { appEscLast = Nothing }
          requestInterrupt
      | otherwise -> modify $ \s -> s { appEscLast = arm }

-- | Keys while a dialog is open: the top dialog owns them all.
handleDialogKey :: Event -> EventM ResourceName AppState ()
handleDialogKey (EvKey KUp [])    = modifyTop (dialogMoveSel (-1))
handleDialogKey (EvKey KDown [])  = modifyTop (dialogMoveSel 1)
handleDialogKey (EvKey (KChar 'p') [MCtrl]) = modifyTop (dialogMoveSel (-1))
handleDialogKey (EvKey (KChar 'n') [MCtrl]) = modifyTop (dialogMoveSel 1)
-- | tab：列表前进（vty 把 Tab 报成 KChar '\t'）。
handleDialogKey (EvKey (KChar '\t') []) = modifyTop (dialogMoveSel 1)
handleDialogKey (EvKey KEnter []) = dialogActivate
handleDialogKey (EvKey KBS [])    = withCommands dialogDelete >> scrollBottom
-- | j/k：没有查询行的列表用 vim 风格上下移动（Reasonix 的 prompts.go）。
-- 有查询行的列表（命令/技能/模型/会话）里 j/k 是普通字符，不抢导航。
handleDialogKey (EvKey (KChar c) [])
  | c == 'j' || c == 'k' = do
      st <- get
      case stackTop (appDialogs st) of
        Just DialogCommands{} -> withCommands (dialogAppend c) >> scrollBottom
        Just DialogSkills{}   -> withCommands (dialogAppend c) >> scrollBottom
        Just DialogModels{}   -> withCommands (dialogAppend c) >> scrollBottom
        Just DialogSessions{} -> withCommands (dialogAppend c) >> scrollBottom
        _ -> modifyTop (dialogMoveSel (if c == 'j' then 1 else -1))
handleDialogKey (EvKey (KChar c) [])
  | let o = fromEnum c in o >= 32 && o < 127 = do
      st <- get
      case stackTop (appDialogs st) of
        Just (DialogProviders ps sel) | c == 'a' ->
          modify $ \s -> s { appDialogs = stackPush (DialogPresets presets 0) (appDialogs s) }
        Just (DialogProviders ps sel) | c == 'e'
          , (p : _) <- drop sel ps -> startWizard (Just p)
        Just (DialogProviders ps sel) | c == 'r'
          , (p : _) <- drop sel ps -> refreshProviderEfforts p
        Just (DialogProviders ps sel) | c == 'd'
          , (p : _) <- drop sel ps -> startProviderRemove p
        Just (DialogProviders ps sel) | c == 't'
          , (p : _) <- drop sel ps -> toggleProviderThinking p
        _ -> withCommands (dialogAppend c) >> scrollBottom
handleDialogKey _ = return ()

-- | Editing keys apply only to the command dialog (approval/confirm have
-- no query row).
dialogAppend :: Char -> Dialog -> Dialog
dialogAppend c d = case d of
  DialogCommands{} -> dialogCommandsAppend c d
  DialogSkills{}   -> dialogSkillsAppend c d
  DialogModels{}   -> dialogModelsAppend c d
  DialogSessions{} -> dialogSessionsAppend c d
  _                -> d

dialogDelete :: Dialog -> Dialog
dialogDelete d = case d of
  DialogCommands{} -> dialogCommandsDelete d
  DialogSkills{}   -> dialogSkillsDelete d
  DialogModels{}   -> dialogModelsDelete d
  DialogSessions{} -> dialogSessionsDelete d
  _                -> d

withCommands :: (Dialog -> Dialog) -> EventM ResourceName AppState ()
withCommands f = do
  st <- get
  case stackTop (appDialogs st) of
    Just DialogCommands{} -> modifyTop f
    Just DialogSkills{}   -> modifyTop f
    -- 模型/会话列表也可过滤：字符输入进查询行，而不是被丢掉。
    Just DialogModels{}   -> modifyTop f
    Just DialogSessions{} -> modifyTop f
    _                     -> return ()

-- | Apply a pure transformation to the top dialog of the stack.
modifyTop :: (Dialog -> Dialog) -> EventM ResourceName AppState ()
modifyTop f = modify $ \s -> s { appDialogs =
  case stackTop (appDialogs s) of
    Just d  -> stackPush (f d) (stackPop (appDialogs s))
    Nothing -> appDialogs s }

-- | Activate the entry under the top dialog's cursor.
-- | Adopt a provider: remember it and make sure the current model belongs
-- to it (otherwise fall back to the provider's default).  The dialog has
-- already been popped by 'dialogActivate'.
chooseProvider :: ProviderInfo -> EventM ResourceName AppState ()
chooseProvider p = do
  lang <- gets appLang
  modify $ \s ->
    let model = modelForProvider p (appModel s)
    in s { appProvider = Just (piName p)
         , appModel = model
         , appStatus = tr lang "Provider: " <> piName p <> " · " <> model }
  st2 <- get
  persistSelection (piName p) (appModel st2)
  scrollBottom

dialogActivate :: EventM ResourceName AppState ()
dialogActivate = do
  st <- get
  case stackTop (appDialogs st) of
    Nothing -> return ()
    Just d -> do
      modify $ \s -> s { appDialogs = stackPop (appDialogs s) }
      case d of
        DialogModels _ _ sel -> case drop sel (dialogModelsItems d) of
          (m : _) -> do
            modify $ \s -> s { appModel = modelName m }
            st2 <- get
            let prefs' = recordRecent (modelName m) (appModelPrefs st2)
            liftIO (saveModelPrefs prefs')
            modify $ \s -> s { appModelPrefs = prefs' }
          []      -> return ()
        DialogSessions _ _ sel -> case drop sel (dialogSessionsItems d) of
          (s : _) -> resumeSession (T.pack (ssId s))
          []      -> return ()
        DialogCommands _ _ sel -> case drop sel (dialogCommandsItems d) of
          (item : _) | not (isSection item) -> handleSlash (piId item)
          _                                 -> return ()
        DialogProviders ps sel -> case drop sel ps of
          (p : _) -> chooseProvider p
          []      -> return ()
        DialogPresets ps sel -> case drop sel ps of
          (p : _) -> startWizardPreset p
          []      -> return ()
        DialogSkills _ _ sel -> case drop sel (dialogSkillsItems d) of
          (sk : _) -> selectSkill (skName sk)
          []       -> return ()
        DialogAgents as sel -> case drop sel as of
          (a : _) -> resumeSession (aeId a)
          []      -> return ()
        DialogThemes ts sel -> case drop sel ts of
          (t : _) -> applyTheme (themeName t)
          []      -> return ()
        DialogLanguages ls sel -> case drop sel ls of
          (l : _) -> applyLanguage l
          []      -> return ()
        DialogApproval _ name args sel ->
          case drop sel (approvalOptions name args) of
            (ApprovalOnce : _)   -> decideApprovalNow True
            (ApprovalAlways : _) -> modifyTop $ \_ ->
              DialogConfirm (alwaysConfirmText (appLang st) name args) 0
            _                    -> decideApprovalNow False
        DialogSandbox ss sel -> do
          st <- get
          let ss' = sandboxApply sel ss
          modify $ \s0 -> s0 { appSandbox = ss' }
          void $ liftIO $ async $ do
            r <- setSandboxConfig (appBridge st) (ssEnabled ss')
                   (ssPolicy ss')
                   (if ssNetwork ss' then "allow:*" else "off")
                   (ssScratch ss')
            case r of
              Left e -> writeBChan (appChan st) (EvToast ("sandbox: " <> T.pack (show e)))
              Right () -> writeBChan (appChan st) (EvToast "sandbox config saved")
        DialogConfirm _ sel -> case sel of
          0 -> do
            st2 <- get
            if appPendingStop st2
              then stopServicesAndHalt
              else case (appPendingProviderRemove st2, appPendingDelete st2) of
                (Just pname, _) -> do
                  modify $ \s -> s { appDialogs = stackPop (appDialogs s)
                                   , appPendingProviderRemove = Nothing
                                   , appStatus = tr (appLang s) "Removing..." }
                  let bridge = appBridge st2
                      chan   = appChan st2
                  void $ liftIO $ async $ do
                    r <- removeProvider bridge pname
                    writeBChan chan (case r of
                      Right ps -> EvProviders (Right ps)   -- registry refresh
                      Left e   -> EvToast (T.pack ("Error: " <> show e)))
                (Nothing, Just sid) -> do
                  modify $ \s -> s { appDialogs = stackPop (appDialogs s)
                                   , appPendingDelete = Nothing
                                   , appStatus = tr (appLang s) "Deleting..." }
                  let bridge = appBridge st2
                      chan = appChan st2
                  void $ liftIO $ async $ do
                    r <- deleteSession bridge sid
                    writeBChan chan (EvToast (case r of
                      Right () -> "Session deleted: " <> T.pack sid
                      Left e   -> "Error: " <> T.pack (show e)))
                (Nothing, Nothing) -> do  -- persist the rule, then approve once
                  modify $ \s -> s { appDialogs = stackPop (appDialogs s) }
                  let (name, args) = fromMaybe ("", []) (appAskTool st2)
                      bridge = appBridge st2
                      chan   = appChan st2
                  case appSessionId st2 of
                    Nothing -> decideApprovalNow True
                    Just sid -> do
                      modify $ \s2 -> s2 { appStatus = tr (appLang s2) "Approving..." }
                      void $ liftIO $ async $ do
                        _ <- allowAlways bridge name args  -- best effort: a failed rule
                                                           -- still allows this once
                        r <- decidePlan bridge sid True
                        writeBChan chan (EvVerdict r)
          _ -> do  -- no: cancel the pending stop, or go back to the approval card
            st2 <- get
            if appPendingStop st2
              then modify $ \s -> s { appPendingStop = False }
              else do
                modify $ \s -> s { appPendingDelete = Nothing, appPendingProviderRemove = Nothing }
                st3 <- get
                case (appApproval st3, appAskTool st3) of
                  (Just msg, Just (name, args)) ->
                    modifyTop (const (DialogApproval msg name args 0))
                  _ -> modify $ \s2 -> s2 { appDialogs = stackPop (appDialogs s2) }

-- | Keys in the normal chat view.
handleChatKey :: Event -> EventM ResourceName AppState ()
handleChatKey (EvKey KPageUp []) =
  vScrollBy (viewportScroll MessageArea) (-10)
handleChatKey (EvKey KPageDown []) =
  vScrollBy (viewportScroll MessageArea) 10
-- | ctrl+o expands/collapses the focused tool card (newest one first).
handleChatKey (EvKey (KChar 'o') [MCtrl]) = do
  st <- get
  -- One turn has many reasoning blocks: Ctrl+O expands them all (or folds
  -- them all when every one is already open).  Tool cards otherwise.
  let ids = [ msgId m | m <- appMessages st, msgRole m == "thinking" ]
      folds = appFolds st
      anyCollapsed = any (\i -> Map.lookup i folds /= Just FoldExpanded) ids
      target = if anyCollapsed then FoldExpanded else FoldCollapsed
  if null ids
    then toggleFocusedCard
    else modify $ \s -> s
      { appFolds = foldl (\mp i -> Map.insert i target mp) (appFolds s) ids }
-- | Ctrl+Y toggles YOLO (Reasonix's danger-full-access preset).
handleChatKey (EvKey (KChar 'y') [MCtrl]) = modeAction (object ["action" .= ("yolo" :: Text)])
-- | Ctrl+V attaches a clipboard image (saved under ~/.trha/paste).
handleChatKey (EvKey (KChar 'v') [MCtrl]) = pasteImage
-- | Ctrl+R records a short voice note (saved under ~/.trha/voice).
handleChatKey (EvKey (KChar 'r') [MCtrl]) = recordVoice
-- | ctrl+e edits the composer in $EDITOR.
handleChatKey (EvKey (KChar 'e') [MCtrl]) = editExternally
-- | alt+↑/↓ moves the tool-card focus.
handleChatKey (EvKey KUp [MAlt]) = moveCardFocus (-1)
handleChatKey (EvKey KDown [MAlt]) = moveCardFocus 1
-- | ctrl+b docks/undocks (or opens/closes) the sidebar.
handleChatKey (EvKey (KChar 'b') [MCtrl]) =
  modify $ \s -> s { appSidebar = toggleSidebar (appSidebar s) }
-- | ctrl+x arms the leader for one keystroke.
handleChatKey (EvKey (KChar 'x') [MCtrl]) =
  modify $ \s -> s { appLeader = True, appStatus = tr (appLang s) leaderHelp }
-- | ctrl+p opens the interactive settings panel (MiMo's command_list is a
-- wizard-style config surface, not the slash-command palette).
handleChatKey (EvKey (KChar 'p') [MCtrl]) = openSettingsPanel
-- | ctrl+g：把折叠的粘贴展开回输入框（Reasonix 的 keepFoldedPastes）。
handleChatKey (EvKey (KChar 'g') [MCtrl]) = do
  st <- get
  case appPastes st of
    [] -> showToast (tr (appLang st) "Nothing to expand")
    pastes -> do
      let expanded = expandPastes pastes (editorValue st)
      modify $ \s -> s
        { appInput = editorText InputArea (Just 1) expanded
        , appPastes = [], appPasteSeq = 0 }
      refreshCompletion >> refreshPalette
      scrollBottom
-- | ctrl+l：清空视图（历史仍在 transcript 里）——Reasonix 的 clearDisplay。
handleChatKey (EvKey (KChar 'l') [MCtrl]) = clearView
-- | ctrl+s：提交（终端里 Enter 已提交，这里补齐习惯键位）。
handleChatKey (EvKey (KChar 's') [MCtrl]) = do
  st <- get
  case appWizard st of
    Just _ -> commitWizard
    Nothing -> handleChatEnter st
-- | ctrl+enter：把当前输入作为 steer 注入运行中的回合。
handleChatKey (EvKey KEnter [MCtrl]) = steerDraft
-- | alt+v：粘贴剪贴板文本（Reasonix 的 pasteClipboardText；ctrl+v 留给图片）。
handleChatKey (EvKey (KChar 'v') [MAlt]) = pasteClipboardText
handleChatKey (EvKey KHome [MCtrl]) =
  vScrollToBeginning (viewportScroll MessageArea)
handleChatKey (EvKey KEnd [MCtrl]) =
  scrollBottom
handleChatKey (EvKey KEnter []) = do
  st <- get
  case appWizard st of
    Just _ -> commitWizard
    Nothing -> handleChatEnter st

-- | alt+enter inserts a newline: the editor only breaks lines on a plain
-- KEnter, so feed it one directly (this skips the submit intercept).
handleChatKey (EvKey KEnter [MAlt]) =
  editDefaultKey (EvKey KEnter []) >> refreshCompletion >> refreshPalette
-- | ↑ recalls history when the cursor is on the first line; inside the
-- input it moves the cursor up one line.  With the @-file popup open it
-- moves the popup selection instead.
handleChatKey (EvKey KUp []) = do
  st <- get
  if T.null (T.strip (editorValue st))
    then vScrollBy (viewportScroll MessageArea) (-1)
    else case appPalette st of
    Just _ -> movePalette (-1)
    Nothing -> case appComp st of
      Just cs -> modify $ \s -> s { appComp = Just (moveCompletion (-1) cs) }
      Nothing -> do
        let cur = T.unlines (getEditContents (appInput st))
        case histUp cur (appHist st) of
          Just (h', entry) | cursorRow (appInput st) == 0 ->
            put st { appHist = h', appInput = editorText InputArea (Just 1) entry }
          _ -> editDefaultKey (EvKey KUp [])
-- | ↓ walks history forward (or restores the draft) when the cursor is on
-- the last line; inside the input it moves the cursor down one line.
handleChatKey (EvKey KDown []) = do
  st <- get
  if T.null (T.strip (editorValue st))
    then vScrollBy (viewportScroll MessageArea) 1
    else case appPalette st of
    Just _ -> movePalette 1
    Nothing -> case appComp st of
      Just cs -> modify $ \s -> s { appComp = Just (moveCompletion 1 cs) }
      Nothing -> do
        let rows = max 1 (length (getEditContents (appInput st)))
        if cursorRow (appInput st) == rows - 1
          then case histDown (appHist st) of
            Just (h', entry) ->
              put st { appHist = h', appInput = editorText InputArea (Just 1) entry }
            Nothing -> editDefaultKey (EvKey KDown [])
          else editDefaultKey (EvKey KDown [])
-- | A leading @/@ on an empty input opens the quick-picker (command menu);
-- any other @/@ is typed into the editor as plain text.
handleChatKey ev = do
  st <- get
  if isJust (appWizard st)
    then editDefaultKey ev
    else editDefaultKey ev >> refreshCompletion >> refreshPalette

-- | Enter outside the wizard: popups, palette, then submit.
handleChatEnter :: AppState -> EventM ResourceName AppState ()
handleChatEnter st
  -- Home: a non-empty submission starts the session view and is sent there.
  | appRoute st == RouteHome
  , not (T.null (T.strip (editorValue st))) = do
      modify $ \s -> s { appRoute = RouteSession }
      handleChatEnter st { appRoute = RouteSession }
  | otherwise =
      case appComp st of
    -- The @-file popup owns Enter while it is open.
    Just cs -> case applySelected (editorValue st) cs of
      Just newText -> do
        modify $ \s -> s { appInput = editorText InputArea (Just 1) newText
                         , appComp = Nothing }
        refreshCompletion
      Nothing -> modify $ \s -> s { appComp = Nothing }
    Nothing ->
      let input = T.strip (editorValue st)
      in case parseSkillInvocation input of
           -- A complete skill trigger submits as one message.  Selecting in
           -- the list only writes this trigger (see 'selectSkill').
           Just (name, args) | any ((== name) . skName) (appSkills st) ->
             when (not (appBusy st)) (submitSkill name args)
           _ -> case appPalette st of
             -- The inline command palette owns Enter while it has a match.
             Just d | not (null (dialogCommandsItems d)) -> runPaletteItem
             _ ->
               if not (T.null input) && not (appBusy st)
                 then commitEditor input >> handleSubmit input
                 -- 空输入回车 = 跟随尾部（Reasonix 的 followTail）；
                 -- 折叠仍由 ctrl+o 负责，不再占用回车。
                 else when (T.null input && not (appBusy st)) scrollBottom
-- | Full editor text: lines joined with newlines (no trailing newline).
editorValue :: AppState -> Text
editorValue st = T.intercalate "\n" (getEditContents (appInput st))

-- | Cursor offset in 'editorValue' units.
editorCursor :: AppState -> Int
editorCursor st =
  sum (map T.length (take row ls)) + row + col
  where
    ls = getEditContents (appInput st)
    (row, col) = getCursorPosition (appInput st)

-- | Recompute the @\@@-file popup from the current text and cursor.
refreshCompletion :: EventM ResourceName AppState ()
refreshCompletion = do
  st <- get
  let popup = completionPopup 8 (appIndex st) (editorValue st) (editorCursor st)
  modify $ \s -> s { appComp = popup }

-- | Palette sources: registered slash commands (grouped by function) plus
-- discovered skills and user commands.
paletteItemsFor :: AppState -> [PickerItem]
paletteItemsFor st =
  -- Recent = the 3 most recently used commands (was 3 commands + 3 skills = 6).
  buildPalette [] (take 3 (ranked cmds)) grouped skills
  where
    lang = appLang st
    skills =
      [ PickerItem ("/skill:" <> skName sk) (skName sk)
          ("skill · " <> skDescription sk)
      | sk <- appSkills st ]
    grouped =
      [ (groupKey g, groupTitle lang g, items)
      | (g, items) <- pickerItemsGrouped lang ]
      ++ [ ("custom", tr lang "custom", customItems) | not (null customItems) ]
    customItems =
      [ PickerItem ("/" <> ccName cc) ("/" <> ccName cc)
          (if T.null (T.strip (ccDescription cc))
             then tr lang "user command"
             else ccDescription cc)
      | cc <- appCustomCmds st ]
    cmds = allPickerItems st
    ranked = rankItems (appFrecency st)

-- | Built-in commands plus user commands (@~/.trha/commands@), flat (used for
-- submit-time matching, which must not see section headers).
allPickerItems :: AppState -> [PickerItem]
allPickerItems st =
  pickerItems (appLang st)
    ++ [ PickerItem ("/" <> ccName cc) ("/" <> ccName cc)
           (if T.null (T.strip (ccDescription cc))
              then tr (appLang st) "user command"
              else ccDescription cc)
       | cc <- appCustomCmds st ]

-- | Recompute the inline slash-command palette from the editor text.  A
-- single-line input starting with @/@ owns the palette; anything else
-- closes it (the list is a hint, not a mode).  A space ends the slash token:
-- once the trigger is chosen (or arguments are being typed) the list is
-- gone, exactly like MiMo's autocomplete.
refreshPalette :: EventM ResourceName AppState ()
refreshPalette = do
  st <- get
  let text = editorValue st
      single = not (T.any (== '\n') text)
      tokenOpen = not (T.any (== ' ') text)
      query = T.drop 1 text
  modify $ \s ->
    if "/" `T.isPrefixOf` text && single && tokenOpen
      then s { appPalette =
             let items = paletteItemsFor s
                 -- 选中索引必须相对于*过滤后*的列表：'dialogCommandsItems'
                 -- 每次都用 query 重新过滤，若这里按全量列表算，过滤到只剩
                 -- 一项时索引会越界，回车便落到 'runPaletteItem' 的空分支上，
                 -- 表现为「输入 /about 回车毫无反应」。
             in Just (DialogCommands items query
                        (dialogCommandsInitialSel items query)) }
      else s { appPalette = Nothing }

-- | Move the palette selection (clamped by the shared dialog state machine).
movePalette :: Int -> EventM ResourceName AppState ()
movePalette delta =
  modify $ \s -> s { appPalette = dialogMoveSel delta <$> appPalette s }

-- | Run the highlighted palette entry and close the palette.
runPaletteItem :: EventM ResourceName AppState ()
runPaletteItem = do
  st <- get
  case appPalette st of
    Nothing -> return ()
    Just d ->
      let its = dialogCommandsItems d
          -- 索引按过滤后的列表钳位：越界时退回最后一项，而不是静默关闭。
          sel = max 0 (min (dialogCommandsSelected d) (length its - 1))
      in case drop sel its of
        (item : _) | isSection item -> modify $ \s -> s { appPalette = Nothing }
        (item : _) ->
          if "/skill:" `T.isPrefixOf` piId item
            then selectSkill (T.drop 7 (piId item))
            else do
              modify $ \s -> s { appInput = editorText InputArea (Just 1) ""
                               , appPalette = Nothing }
              handleSlash (piId item)
        [] -> modify $ \s -> s { appPalette = Nothing }

-- | Persist the active provider/model so the next launch starts there.
persistSelection :: Text -> Text -> EventM ResourceName AppState ()
persistSelection providerName model = do
  st <- get
  let cfg = (appEffCfg st) { configProvider = providerName, configModel = model }
  liftIO $ saveConfig cfg
  modify $ \s -> s { appEffCfg = cfg }

-- | Begin adding (Nothing) or editing (Just provider) a provider.
startWizardPreset :: Preset -> EventM ResourceName AppState ()
startWizardPreset p = do
  st <- get
  let w = ProviderWizard 0 (preName p) (preKind p) (preBaseUrl p)
            (T.intercalate "," (preModels p))
            (fromMaybe "" (listToMaybe (preModels p))) "" "" "" "yes" "no" "" "" "" "" ""
  modify $ \s -> s { appWizard = Just w
                   , appDialogs = stackPop (appDialogs s)
                   , appPalette = Nothing
                   , appInput = editorText InputArea (Just 1) ""
                   , appStatus = tr (appLang st) "Provider wizard 1/6: "
                       <> head wizardPrompts }
  refreshWizardInput w

-- | Re-probe a saved provider and write its effort ladder back (a relay may
-- have gained or lost a model's depth levels since it was saved).
-- | 思考开关（tui-port L290）：翻转 piThinking（yes↔no）并经 saveProvider
-- 持久化。DialogProviders 的 't' 与 settings 的 Providers 页签共用。
toggleProviderThinking :: ProviderInfo -> EventM ResourceName AppState ()
toggleProviderThinking p = do
  st <- get
  let bridge = appBridge st
      chan   = appChan st
      next   = if piThinking p == "yes" then "no" else "yes"
  modify $ \s -> s { appStatus = tr (appLang st) "Saving thinking toggle..." }
  void $ liftIO $ async $ do
    r <- saveProvider bridge (piName p) (piKind p) (piBaseUrl p) ""
           (piModels p) (piDefault p) (piAuthHeader p) (piNoProxy p)
           (piEffort p) (piVision p) (piEfforts p)
           (piHeaders p) (piExtraBody p) next (piResponsesMode p)
           (piContextWindow p)
    writeBChan chan (case r of
      Right _  -> EvToast (T.pack "thinking: " <> next)
      Left e   -> EvToast (T.pack ("Error: " <> show e)))

-- | 删除确认入口（tui-port L290）：pending 标记 + DialogConfirm（默认取消）。
-- 确认后的实际删除在 DialogConfirm 分发（appPendingProviderRemove）。
startProviderRemove :: ProviderInfo -> EventM ResourceName AppState ()
startProviderRemove p = do
  st <- get
  modify $ \s -> s
    { appPendingProviderRemove = Just (piName p)
    , appDialogs = stackPush
        (DialogConfirm (T.pack ("Remove provider " <> T.unpack (piName p) <> "?")) 1)
        (appDialogs st) }

refreshProviderEfforts :: ProviderInfo -> EventM ResourceName AppState ()
refreshProviderEfforts p = do
  st <- get
  let bridge = appBridge st
      chan = appChan st
  modify $ \s -> s { appStatus = "Probing " <> piName p <> "..." }
  void $ liftIO $ async $ do
    r <- probeProvider bridge (piBaseUrl p) ""
    case r of
      Right probe -> do
        saved <- saveProvider bridge (piName p) (piKind p) (piBaseUrl p) ""
                   (piModels p) (piDefault p) (piAuthHeader p) (piNoProxy p)
                   (piEffort p) (piVision p) (ppEfforts probe)
                   (piHeaders p) (piExtraBody p) (piThinking p) (piResponsesMode p)
                   (piContextWindow p)
        writeBChan chan (EvProviderSaved saved)
      Left e -> writeBChan chan (EvProviderSaved (Left e))

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

-- | Put the current field's value in the editor so the user can edit it.
refreshWizardInput :: ProviderWizard -> EventM ResourceName AppState ()
refreshWizardInput w = do
  modify $ \s -> s { appWizard = Just w
                   , appInput = editorText InputArea (Just 1) (wizardValue w (pwStep w)) }

-- | Take the editor's text as the current field and advance (or save).
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

-- | A non-blank field that does not decode as JSON.
invalidJson :: Text -> Bool
invalidJson t
  | T.null (T.strip t) = False
  | otherwise = case (decode (BL.fromStrict (TE.encodeUtf8 t)) :: Maybe Value) of
      Just _  -> False
      Nothing -> True

-- | Validate and POST the draft; the kernel answers with the new store.
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

-- | Select a skill in the palette: write the trigger into the editor and
-- stop there.  MiMo's @DialogSkill@ does exactly this (@setText("/"+name+" ")@,
-- cursor to the end); running the skill is the submit key's job, never the
-- list's.
selectSkill :: Text -> EventM ResourceName AppState ()
selectSkill name =
  modify $ \s -> s { appInput = editorText InputArea (Just 1) ("/skill:" <> name <> " ")
                   , appPalette = Nothing }

-- | Run a skill.  The transcript shows the visible trigger (@/skill:<name>
-- <request>@) while the model receives the skill's instructions plus the
-- user's own request — the same split MiMo uses (visible message + body
-- injected as context).
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
editDefaultKey :: Event -> EventM ResourceName AppState ()
editDefaultKey ev = do
  st <- get
  newInput <- nestEventM' (appInput st) $ handleEditorEvent (VtyEvent ev)
  put st { appInput = newInput }

-- | The editor's cursor row (0 = first line of a multi-line input).
-- brick 3.0's getCursorPosition returns the zipper's @(row, col)@.
cursorRow :: Editor Text ResourceName -> Int
cursorRow ed = fst (getCursorPosition ed)

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
modeAction :: Value -> EventM ResourceName AppState ()
modeAction body = do
  st <- get
  case appSessionId st of
    Nothing -> do
      -- No session yet: cycle the label locally so the shortcut still
      -- responds (Studio updates its status without a round trip too).
      let cur = maybe "read-only" smMode (appMode st)
          nextOf m = case m of
            "read-only" -> "ask"
            "ask"       -> "auto"
            "auto"      -> "yolo"
            "yolo"      -> "plan"
            _           -> "read-only"
          nxt = nextOf cur
          -- plan is a flag (scheduler parity): the approval mode stays ask.
          mode' = if nxt == "plan" then "ask" else nxt
          label = case nxt of
            "read-only" -> "Read only"
            "ask"       -> "Ask"
            "auto"      -> "Auto"
            "yolo"      -> "YOLO"
            _           -> "Plan"
      modify $ \s -> s
        { appMode = Just (SessionMode mode' label (nxt == "plan") Nothing)
        , appStatus = tr (appLang s) "Mode switched" }
    Just sid -> do
      let bridge = appBridge st
          chan = appChan st
      void $ liftIO $ async $ applySessionMode bridge sid body >>= writeBChan chan . EvMode
  scrollBottom

-- | Show a transient notice and schedule its dismissal.  The stamp keeps a
-- late timer from clearing a newer toast.
showToast :: Text -> EventM ResourceName AppState ()
showToast msg = do
  t <- liftIO getCurrentTime
  st <- get
  modify $ \s -> s { appToast = Just (msg, t) }
  void $ liftIO $ async $ do
    threadDelay 3000000
    writeBChan (appChan st) (EvToastExpire t)

-- | Pull the session's posture (after creation/restore).
refreshMode :: SchedulerBridge -> SessionId -> BChan AppEvent -> IO ()
refreshMode bridge sid chan =
  void $ async $ fetchSessionMode bridge sid >>= writeBChan chan . EvMode

-- | Tool-card ids in display order (hidden cards excluded, so focus never
-- lands on something the viewport does not draw).
toolCardIds :: AppState -> [Int]
toolCardIds st = [ msgId m | m <- appMessages st, isJust (msgTool m), not (cardHidden st m) ]

-- | Move the tool-card focus (alt+↑/↓), clamped to the newest/oldest card.
moveCardFocus :: Int -> EventM ResourceName AppState ()
moveCardFocus delta = do
  st <- get
  let ids = toolCardIds st
  modify $ \s -> s { appCardFocus = nextCardFocus ids (appCardFocus s) delta }
  scrollBottom

-- | Toggle the focused card (ctrl+o, or Enter on empty input).  With no focus
-- yet this picks the newest card, then flips it — the old single-card
-- behaviour, now with a movable focus (MiMo parity).
toggleFocusedCard :: EventM ResourceName AppState ()
toggleFocusedCard = do
  st <- get
  let ids = toolCardIds st
  case nextCardFocus ids (appCardFocus st) 0 of
    Nothing -> return ()
    Just mid ->
      modify $ \s -> s { appCardFocus = Just mid
                       , appFolds = Map.alter (Just . toggleFold . fromMaybe FoldCollapsed) mid (appFolds s) }
  scrollBottom

-- | Ensure a streaming block is open for the current assistant reply.
ensurePending :: EventM ResourceName AppState ()
ensurePending = do
  st <- get
  case appPending st of
    Just _ -> return ()
    Nothing -> do
      t <- liftIO now
      modify $ \s -> s { appPending = Just (newPending t) }

-- | Append a text delta to the open assistant block.
appendDelta :: Text -> EventM ResourceName AppState ()
appendDelta text = do
  -- Deltas are a live preview only.  Once the authoritative reply has
  -- closed the turn (busy = False), a late stream event must not reopen a
  -- pending block that nothing will ever flush.
  busy <- gets appBusy
  when busy $ do
    ensurePending
    modify $ \s -> s { appPending =
      (\pm -> pm { pmContent = pmContent pm <> text }) <$> appPending s }

-- | Append a reasoning (thinking) delta.  Same late-event rule as text
-- deltas: only while the turn is live.
appendReasoningDelta :: Text -> EventM ResourceName AppState ()
appendReasoningDelta text = do
  busy <- gets appBusy
  when busy $ do
    ensurePending
    modify $ \s -> s { appPending = appendReasoning text <$> appPending s }

-- | Record a tool invocation in the open block.
addToolLine :: ToolName -> [Text] -> EventM ResourceName AppState ()
addToolLine name args = do
  ensurePending
  let inv = ToolInv name args
  modify $ \s -> s { appPending = (\pm -> pm { pmTools = inv : pmTools pm }) <$> appPending s }

-- | Close the streaming block and persist it as chat messages.  @musage@ is
-- this turn's usage echo (the model + token footer); Nothing on failure.
flushPending :: Maybe Usage -> EventM ResourceName AppState ()
flushPending musage = do
  t1 <- liftIO getCurrentTime
  flushPendingAt musage t1

flushPendingAt :: Maybe Usage -> UTCTime -> EventM ResourceName AppState ()
flushPendingAt musage t1 = do
  st <- get
  case appPending st of
    -- The turn is over even if no block was open (e.g. a duplicate terminal
    -- event): never leave the spinner running.
    Nothing -> modify $ \s -> s { appBusy = False }
    Just pm -> do
      let base = appNextMsgId st
          stampedFrom base0 ms = zipWith (\i m -> m { msgId = base0 + i }) [0 ..] ms
          meta = metaLine (appModel st) musage
          withMeta m
            | not (T.null meta) = m { msgMeta = Just meta }
            | otherwise = m
          toolMsgs = [ toolMsg "tool" (ToolCard (tiName inv) (tiArgs inv) Nothing Nothing [] "") (pmStart pm)
                     | inv <- reverse (pmTools pm) ]
          thinkText = flushThinking pm
          thinkSecs = case appTurnStart st of
            Just t0 -> max 0 (round (realToFrac (diffUTCTime t1 t0) :: Double))
            Nothing -> 0
          thinkLabel = "思考了 " <> T.pack (show thinkSecs) <> " 秒 (Ctrl+O)"
          thinkMsgs = [ (mkMsg "thinking" thinkText (pmStart pm)) { msgMeta = Just thinkLabel }
                      | not (T.null thinkText) ]
          textMsgs = [ withMeta (mkMsg "assistant" (T.strip (pmContent pm)) (pmStart pm))
                     | not (T.null (T.strip (pmContent pm)))
                     , not (isAwaitReply (pmContent pm)) ]
          -- A parked turn: the kernel's permission gate (ask rules) returned
          -- early with "awaiting_approval: <REQUIRE_APPROVAL: reason>". The
          -- partial stream is real content, so flush it, then lock the flow
          -- and open the approval dialog.
          isAwaitReply c = "awaiting_approval:" `T.isPrefixOf` c
          awaitMsg = case drop 1 [ T.strip (T.drop 18 c) | c <- [T.strip (pmContent pm)], isAwaitReply c ] of
            (m : _) -> m
            []      -> ""
          parked = isAwaitReply (T.strip (pmContent pm)) && not (T.null awaitMsg)
          (askName, askArgs) = fromMaybe ("", []) (appAskTool st)
      modify $ \s -> s { appMessages = appMessages s
                                      ++ stampedFrom base thinkMsgs
                                      ++ stampedFrom (base + length thinkMsgs) toolMsgs
                                      ++ stampedFrom (base + length thinkMsgs + length toolMsgs) textMsgs
                       , appNextMsgId = base + length thinkMsgs + length toolMsgs + length textMsgs
                       , appPending = Nothing
                       -- A finished turn is never busy: parked approvals
                       -- clear the spinner too, otherwise the input stays
                       -- locked on "Thinking..." after every normal reply.
                       , appBusy = False
                       , appApproval = if parked then Just awaitMsg else appApproval s
                       , appDialogs = if parked
                                        then stackPush (DialogApproval awaitMsg askName askArgs 0) (appDialogs s)
                                        else appDialogs s
                       , appStatus = if parked
                                       then tr (appLang s) "Awaiting approval..."
                                       else tr (appLang s) "Ready" }

-- | Async events from background workers
handleAppEvent :: AppEvent -> EventM ResourceName AppState ()
handleAppEvent (EvSession result) = do
  case result of
    Right sid -> do
      st <- get
      -- Auto-created sessions are recorded silently so that the system
      -- message does not interleave between the user message and the reply.
      modify $ \s -> s { appSessionId = Just sid, appStatus = tr (appLang s) "Ready"
                       , appBusy = False
                       , appRoute = RouteSession
                       , appCacheNow = Nothing
                       , appCacheSum = (0, 0)
                       , appCacheTurns = 0
                       , appLastCost = 0
                       , appSessTokens = 0
                       , appLastDecodeTps = Nothing
                       , appFirstToken = Nothing }
      liftIO $ setWindowTitle ("trha · " <> T.take 8 (T.pack sid))
      liftIO $ refreshMode (appBridge st) sid (appChan st)
    Left err -> do
      lang <- gets appLang
      t <- liftIO now
      appendMsg (mkMsg "error" (tr lang "Session failed: " <> T.pack (show err)) t)
      modify $ \st -> st { appStatus = tr (appLang st) "Error", appBusy = False }
  scrollBottom
handleAppEvent (EvResponse result) = case result of
  Right chunk -> case chunk of
    ChunkDelta text    -> do
      -- The first delta ends the TTFT window; the pure-decode rate is measured
      -- from here, to the final usage.  Recorded once per turn.
      first <- gets appFirstToken
      when (isNothing first) $ do
        t <- liftIO getCurrentTime
        modify $ \s -> s { appFirstToken = Just t }
      appendDelta text
      scrollBottom
    ChunkToolCall n as -> addToolLine n as >> scrollBottom
    ChunkDone usage    -> do
      let real = usageTotalTokens usage > 0
          hit = usageCacheHitTokens usage
          miss = usageCacheMissTokens usage
          cacheSeen = real && hit + miss > 0
      st0 <- get
      t1 <- liftIO getCurrentTime
      let elapsed = maybe 0 (\t0 -> realToFrac (diffUTCTime t1 t0)) (appTurnStart st0)
                    :: Double
          tps = if real && elapsed > 0 && usageCompletionTokens usage > 0
                  then Just (fromIntegral (usageCompletionTokens usage) / elapsed)
                  else appLastTps st0
          -- Same numerator, but the clock starts at the first token: this is
          -- the number a provider's own dashboard reports as "t/s".
          decodeTps = case (appFirstToken st0, usageCompletionTokens usage) of
            (Just tFirst, n) | real && n > 0 ->
              let d = realToFrac (diffUTCTime t1 tFirst) :: Double
              in if d > 0.02 then Just (fromIntegral n / d) else Nothing
            _ -> appLastDecodeTps st0
      modify $ \s -> s { appLastUsage = Just (usageTotalTokens usage)
                       , appUsage = if real then Just usage else appUsage s
                       , appCacheNow = if cacheSeen then Just (hit, miss) else appCacheNow s
                       , appCacheSum = if cacheSeen
                                         then let (h0, m0) = appCacheSum s
                                              in (h0 + hit, m0 + miss)
                                         else appCacheSum s
                       , appCacheTurns = if cacheSeen
                                           then appCacheTurns s + 1
                                           else appCacheTurns s
                       , appCtxUsed = if usagePromptTokens usage > 0
                                        then Just (usagePromptTokens usage
                                                   + usageCompletionTokens usage)
                                        else appCtxUsed s
                       , appLastTps = tps
                       , appLastDecodeTps = decodeTps
                       , appCostSum = appCostSum s + estimateCost (pricesOf (appModel s) (appEffCfg s)) usage
                       , appLastCost = estimateCost (pricesOf (appModel s) (appEffCfg s)) usage
                       , appSessTokens = appSessTokens s + usageTotalTokens usage
                       , appFirstToken = Nothing
                       , appTurnStart = Nothing }
      flushPending (if real then Just usage else Nothing)
      st3 <- get
      let summary = turnSummary (pricesOf (appModel st3) (appEffCfg st3)) usage (usageReasoningTokens usage) t1
      appendMsg (mkMsg "stats" summary "")
      bell <- gets (configBell . appEffCfg)
      when bell $ liftIO (putStr "\a" >> hFlush stdout)
      scrollBottom
  Left err -> do
    flushPending Nothing -- keep whatever partial content already arrived
    t <- liftIO now
    let msg = T.pack (show err)
        staleSession = "not found" `T.isInfixOf` T.toLower msg
    lang0 <- gets appLang
    if staleSession
      then do
        -- The scheduler keeps sessions in memory; a restart (or a session
        -- deleted elsewhere) turns the id the TUI holds into a 404.  Drop it
        -- so the next message creates a fresh session instead of 404-ing.
        appendMsg (mkMsg "system"
          (tr lang0 "The session no longer exists on the scheduler; the next message creates a new one.") t)
        modify $ \st -> st { appSessionId = Nothing
                           , appStatus = tr (appLang st) "Session expired"
                           , appCacheNow = Nothing
                           , appCacheSum = (0, 0)
                           , appCacheTurns = 0
                           , appLastCost = 0
                           , appSessTokens = 0
                           , appLastDecodeTps = Nothing
                           , appFirstToken = Nothing }
      else appendMsg (mkMsg "error" ("Error: " <> msg) t)
    bell <- gets (configBell . appEffCfg)
    when bell $ liftIO (putStr "\a" >> hFlush stdout)
    modify $ \st -> st { appStatus = tr (appLang st) "Error", appBusy = False }
    scrollBottom
handleAppEvent (EvNotice notice) = case notice of
  ReasoningDelta text -> appendReasoningDelta text >> scrollBottom
  StepStarted rnd msgs tools -> do
    -- A new model round starts.  Close whatever the previous round left in
    -- the streaming block so the separator lands in the right place, then
    -- restore the turn's busy/status (flushPending is a turn-end action).
    st0 <- get
    when (isJust (appPending st0)) $ do
      flushPending Nothing
      modify $ \s -> s { appBusy = appBusy st0, appStatus = appStatus st0 }
    t <- liftIO now
    appendMsg (mkMsg "step"
      ("round " <> T.pack (show rnd) <> " · " <> T.pack (show msgs)
        <> " msgs · " <> T.pack (show tools) <> " tools") t)
    scrollBottom
  ContextCompacted trigger saved -> do
    t <- liftIO now
    appendMsg (mkMsg "compact"
      ("context compacted (" <> trigger <> ") · saved "
        <> T.pack (show saved) <> " tokens") t)
    scrollBottom
  RetryScheduled attempt delayMs reason -> do
    t <- liftIO now
    appendMsg (mkMsg "retry"
      ("retry " <> T.pack (show attempt) <> "/3 in "
        <> T.pack (show delayMs) <> "ms — " <> reason) t)
    scrollBottom

handleAppEvent (EvMode result) = case result of
  Right m -> do
    lang0 <- gets appLang
    -- 左侧 modeTag 已经显示模式名，appStatus 再写一遍就是「Read only ·
    -- 模式：Read only」。这里只确认「切换完成」。
    modify $ \s -> s { appMode = Just m
                     , appStatus = tr (appLang s) "Mode switched" }
    showToast (tr lang0 "Mode: " <> smLabel m)
  Left e  -> modify $ \s -> s { appStatus = "Mode: " <> T.pack (show e) }

handleAppEvent (EvSidebarInfo cwd files instrs) =
  modify $ \s -> s { appCwd = cwd, appFiles = files, appInstructions = instrs }

handleAppEvent (EvSessionInfo (Right info)) =
  modify $ \s -> s { appTodos = siTodos info, appGoal = siGoal info }
handleAppEvent (EvSessionInfo (Left _)) = return ()

handleAppEvent (EvAgents (Right as)) = modify $ \s -> s { appAgents = as }
handleAppEvent (EvAgents (Left _)) = return ()
handleAppEvent (EvServices lsp mcp) = modify $ \s -> s { appLsp = lsp, appMcp = mcp }
handleAppEvent (EvBalance (Right b)) = modify $ \s -> s { appBalance = Just b }
handleAppEvent (EvBalance (Left _)) = return ()
handleAppEvent (EvSandboxConfig (Right on)) = modify $ \s ->
  s { appSandbox = (appSandbox s) { ssEnabled = on } }
handleAppEvent (EvSandboxConfig (Left _)) = return ()

handleAppEvent (EvRecent xs) = modify $ \s -> s { appRecent = xs }

handleAppEvent (EvToast msg) = showToast msg

handleAppEvent (EvToastExpire t) =
  modify $ \s -> case appToast s of
    Just (_, t0) | t0 == t -> s { appToast = Nothing }
    _                      -> s

handleAppEvent (EvSessions result) = do
  lang <- gets appLang
  t <- liftIO now
  case result of
    Right [] -> appendMsg (mkMsg "system" (tr lang "No sessions.") t)
    Right sids -> do
      cwd <- liftIO getCurrentDirectory
      local <- liftIO (listLocalSessionsIn cwd)
      modify $ \s -> s { appDialogs = stackPush (DialogSessions local "" 0) (appDialogs s) }
      -- legacy ids row kept for parity with the REPL
      appendMsg (mkMsg "system" ((tr lang "Sessions:" <> "\n")
                       <> T.unlines (map (\s -> "  • " <> T.pack s) sids)) t)
    Left err -> appendMsg (mkMsg "system" (tr lang "Error: " <> T.pack (show err)) t)
  scrollBottom
handleAppEvent (EvModels result) = do
  lang <- gets appLang
  t <- liftIO now
  case result of
    Right [] -> appendMsg (mkMsg "system" (tr lang "No models available.") t)
    Right ms -> do
      st <- get
      case stackTop (appDialogs st) of
        Just (DialogModels _ _ _) ->
          modifyTop (const (DialogModels (orderedModels (appModelPrefs st) ms) "" 0))
        _ -> appendMsg (mkMsg "system" ((tr lang "Models:" <> "\n") <> T.unlines
                         (map (\m -> "  • " <> modelName m <> " — " <> modelDescription m) ms)) t)
    Left err -> do
      st <- get
      case stackTop (appDialogs st) of
        Just (DialogModels _ _ _) -> modify $ \s -> s { appDialogs = stackPop (appDialogs s) }
        _ -> return ()
      appendMsg (mkMsg "error" (tr lang "Error: " <> T.pack (show err)) t)
  scrollBottom
handleAppEvent (EvDeleted sid) = do
  lang <- gets appLang
  t <- liftIO now
  appendMsg (mkMsg "system" (tr lang "Deleted session: " <> T.pack sid) t)
  showToast (tr lang "Deleted session: " <> T.pack sid)
  scrollBottom
handleAppEvent (EvPlan result) = do
  t <- liftIO now
  case result of
    Right (PlanAwaiting preview) ->
      appendMsg (mkMsg "plan" ("⏸ " <> preview) t)
    Left err -> do
      appendMsg (mkMsg "error" (T.pack (show err)) t)
      modify $ \st -> st { appStatus = tr (appLang st) "Error", appBusy = False }
  scrollBottom
handleAppEvent (EvPlanState result) = do
  lang <- gets appLang
  t <- liftIO now
  case result of
    Right (pv, reply) -> do
      -- Mirror the kernel's plan to ~/.trha/plans/ so it survives the session.
      sid <- gets appSessionId
      forM_ sid $ \s -> void (liftIO (savePlanSnapshot (T.pack s) pv))
      modify $ \st -> st { appPlan = Just pv, appStatus = tr lang "Plan", appBusy = False }
      case reply of
        Just txt | not (T.null txt) -> appendMsg (mkMsg "assistant" txt t)
        _ -> pure ()
    Left err -> do
      appendMsg (mkMsg "error" (T.pack (show err)) t)
      modify $ \st -> st { appStatus = tr lang "Error", appBusy = False }
  scrollBottom

handleAppEvent (EvVerdict result) = do
  lang <- gets appLang
  t <- liftIO now
  case result of
    Right (PlanApproved reply) -> do
      appendMsg (mkMsg "assistant" reply t)
      modify $ \st -> st { appStatus = tr (appLang st) "Ready", appBusy = False
                         , appApproval = Nothing }
    Right PlanDenied -> do
      appendMsg (mkMsg "system" (tr lang "Plan denied.") t)
      modify $ \st -> st { appApproval = Nothing, appBusy = False }
    Left err -> do
      appendMsg (mkMsg "error" (T.pack (show err)) t)
      modify $ \st -> st { appStatus = tr (appLang st) "Error", appBusy = False }
  scrollBottom
handleAppEvent EvTick = do
  t <- liftIO getCurrentTime
  modify $ \s -> s { appNow = Just t }

handleAppEvent (EvStatusInfo rows) = do
  modify $ \s -> s { appSysRows = rows }
handleAppEvent (EvMetrics rows) = do
  modify $ \s -> s { appMetrics = rows }
handleAppEvent (EvGitStat t) = modify $ \s -> s { appGitStat = t }
handleAppEvent (EvTool result) = do
  lang <- gets appLang
  t <- liftIO now
  case result of
    Right ev -> do
      -- running events only update the status line; completed events
      -- become tool cards
      modify $ \st -> st { appStatus = tr (appLang st) "tool: " <> T.pack (teName ev) <> " " <> tr (appLang st) (statusTagOf (teStatus ev)) }
      -- a permission ask parks the turn: keep the tool identity for the
      -- approval dialog ("always" derives its rule pattern from it)
      when (case teStatus ev of
              ToolRunFailed err -> "REQUIRE_APPROVAL:" `T.isPrefixOf` err
              _                 -> False) $ do
        asked <- liftIO getCurrentTime
        modify $ \st -> st { appAskTool = Just (teName ev, teArgs ev)
                           , appAskAt = Just asked }
      case teStatus ev of
        ToolRunRunning -> do
          -- A long tool call used to be invisible until it finished: the card
          -- only existed once the closing event arrived. Open the card now and
          -- remember which message it is, so `end` can rewrite it.
          appendMsg (toolCardMsg ev t)
          st <- get
          -- `appendMsg` appends, so the message just added is the last one and
          -- its id is (length - 1); `listToMaybe` would hand back the oldest.
          let mid = length (appMessages st) - 1
          when (not (T.null (teCallId ev))) $
            modify $ \s -> s { appRunningTools =
              Map.insert (teCallId ev) mid (appRunningTools s) }
        _ -> do
          st <- get
          let running = Map.lookup (teCallId ev) (appRunningTools st)
          case running of
            Just mid -> do
              -- Rewrite the opening card in place: one call, one card.
              modify $ \s -> s
                { appMessages = map (\m -> if msgId m == mid then toolCardMsg ev t else m)
                                  (appMessages s)
                , appRunningTools = Map.delete (teCallId ev) (appRunningTools s)
                }
            Nothing -> appendMsg (toolCardMsg ev t)
    Left err -> do
      appendMsg (mkMsg "error" (tr lang "SSE: " <> T.pack (show err)) t)
      modify $ \st -> st { appStatus = tr (appLang st) "Error" }
  scrollBottom
handleAppEvent (EvToggleToolFold mid) = do
  -- Flip the fold state of the tool message with the given id.
  modify $ \s -> s { appFolds =
    Map.alter (Just . toggleFold . fromMaybe FoldCollapsed) mid (appFolds s) }
  scrollBottom
handleAppEvent (EvCtxSize cs) = do
  modify $ \s -> s { appCtxSize = Just cs }
handleAppEvent (EvTodos (Right ts)) = do
  modify $ \s -> s { appTodos = ts }
handleAppEvent (EvTodos (Left _)) = return ()
handleAppEvent (EvSessionTitle mt) = do
  modify $ \s -> s { appSessionTitle = mt }
handleAppEvent (EvCompletionIndex ix) = do
  modify $ \s -> s { appIndex = ix }
handleAppEvent (EvProviders (Right ps)) = do
  modify $ \s -> s { appProviders = ps }
  -- The dialog is pushed empty while the fetch is in flight; fill it in
  -- place so the user does not have to reopen it.
  st <- get
  case stackTop (appDialogs st) of
    Just (DialogProviders _ _) -> modifyTop (const (DialogProviders ps 0))
    _                          -> return ()
handleAppEvent (EvProviders (Left _)) = return ()
handleAppEvent (EvSkills skills) = do
  modify $ \s -> s { appSkills = skills }
handleAppEvent (EvProviderSaved (Right ps)) = do
  modify $ \s -> s { appProviders = ps
                   , appStatus = tr (appLang s) "Provider saved" }
  lang <- gets appLang
  showToast (tr lang "Provider saved")
handleAppEvent (EvProviderSaved (Left e)) = do
  modify $ \s -> s { appStatus = "Provider save failed: " <> T.pack (show e) }
handleAppEvent (EvFinalReply text) = do
  -- The step reply is authoritative: replace whatever the preview has
  -- accumulated (a dropped delta must not truncate the answer).
  st <- get
  t <- liftIO now
  let pm = fromMaybe (newPending t) (appPending st)
  modify $ \s -> s { appPending = Just pm { pmContent = text } }
  scrollBottom

-- | Tool-card message from a completed lifecycle event (with output
-- preview lines from the kernel tail).
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
approveAndRun :: SchedulerBridge -> SessionId -> IO (Either CLIError (PlanView, Maybe Text))
approveAndRun bridge sid = do
  approved <- decideStep bridge sid "approve"
  case approved of
    Left e -> pure (Left e)
    Right pv -> case planStepOut pv of
      Nothing -> pure (Right (pv, Nothing))
      Just step -> do
        ran <- sendMessage bridge sid (psvTitle step)
        let ok = either (const False) (const True) ran
            reply = either (const Nothing) (Just . chunkText) ran
        reported <- reportStep bridge sid (psvId step) ok
        pure $ case reported of
          Left e    -> Left e
          Right pv' -> Right (pv', reply)
  where
    chunkText (ChunkDelta t) = t
    chunkText _              = ""

-- | Status text for the footer/status line.
statusTagOf :: ToolRunStatus -> Text
statusTagOf ToolRunRunning   = "running…"
statusTagOf ToolRunSucceeded = "✓"
statusTagOf (ToolRunFailed _) = "✗"

-- | Render a tool card with its status footer (message text).
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
toCardStatus :: ToolRunStatus -> ToolStatus
toCardStatus s = case s of
  ToolRunRunning   -> ToolRunning
  ToolRunSucceeded -> ToolSucceeded
  ToolRunFailed e  -> ToolFailed e

-- | Dispatch submitted input: open the quick picker when a slash prefix is
-- ambiguous, otherwise run the command / send the chat message.
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
runShellCommand :: Text -> EventM ResourceName AppState ()
runShellCommand cmd = do
  t <- liftIO now
  appendMsg (mkMsg "shell" ("$ " <> cmd) t)
  r <- liftIO (runLocalShell cmd)
  case r of
    Left e -> appendMsg (mkMsg "error" e t)
    Right (code, out, err) -> do
      let body = T.take 20000 (T.pack (out <> err))
          suffix = case code of
            ExitSuccess -> ""
            ExitFailure n -> "\n(exit " <> T.pack (show n) <> ")"
      appendMsg (mkMsg "shell" (body <> suffix) t)
  scrollBottom

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
  case cmd of
    "/help" ->
      appendMsg (mkMsg "system" (helpTextFor (appLang st)) t)
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
    "/clear" -> do
      modify $ \s -> s { appMessages = [], appFolds = Map.empty, appCardFocus = Nothing }
      showToast (tr lang "Cleared")
    "/new" -> do
      st0 <- get
      -- 把当前姿态带进新会话：Shift+Tab/Ctrl+Y 选的是「待用姿态」，
      -- 只有落到 createSession 才算真的切换（否则服务端仍是 read-only）。
      let pm = smMode <$> appMode st0
      modify $ \s -> s { appBusy = True, appStatus = "Creating session..." }
      void $ liftIO $ async $
        createSession bridge pm >>= writeBChan chan . EvSession
    "/settings"
      | T.null (T.strip (T.drop 9 input)) -> openSettingsPanel
      | otherwise -> do
          let arg = T.strip (T.drop 9 input)
          msg <- liftIO (runSettingsCommand lang arg)
          forM_ msg $ \m -> appendMsg (mkMsg "system" m t)
          scrollBottom
    "/sessions" -> do
      cwd <- liftIO getCurrentDirectory
      local <- liftIO (listLocalSessionsIn cwd)
      if null local
        then appendMsg (mkMsg "system" (tr lang "No local sessions in this directory yet. Run a conversation first.") t)
        else modify $ \s -> s { appDialogs = stackPush (DialogSessions local "" 0) (appDialogs s) }
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
    "/copy" -> do
      st2 <- get
      t2 <- liftIO now
      case [ m | m <- reverse (appMessages st2), msgRole m == "assistant", not (T.null (msgContent m)) ] of
        (m : _) -> do
          ok <- liftIO $ copyToClipboard (msgContent m)
          if ok
            then showToast (tr lang "Copied to clipboard")
            else do
              tmp <- liftIO getTemporaryDirectory
              let path = tmp </> "trha-copy.txt"
              liftIO $ TIO.writeFile path (msgContent m)
              appendMsg (mkMsg "system"
                (tr lang "Clipboard unavailable; wrote " <> T.pack path) t2)
        [] -> appendMsg (mkMsg "system" (tr lang "No assistant message to copy") t2)
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
    "/rename" -> do
      st2 <- get
      let title = T.strip (T.drop 7 input)
      case appSessionId st2 of
        Nothing -> appendMsg (mkMsg "system" (tr lang "No active session.") t)
        Just sid -> do
          r <- liftIO $ renameSession (appBridge st2) sid title
          case r of
            Right _ -> showToast (tr lang "Renamed")
            Left e  -> appendMsg (mkMsg "error" (T.pack (show e)) t)
    "/tag" -> do
      st2 <- get
      let tags = T.words (T.drop 4 input)
      case appSessionId st2 of
        Nothing -> appendMsg (mkMsg "system" (tr lang "No active session.") t)
        Just sid -> do
          r <- liftIO $ tagSession (appBridge st2) sid tags
          case r of
            Right _ -> showToast (tr lang "Tags updated")
            Left e  -> appendMsg (mkMsg "error" (T.pack (show e)) t)
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
    "/quit" -> halt
    "/exit" -> halt
    "/status" ->
      appendMsg (mkMsg "system" (statusLine st) t)
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
refreshSidebar :: SchedulerBridge -> BChan AppEvent -> SessionId -> IO ()
refreshSidebar bridge chan sid = do
  info <- fetchSessionInfo bridge sid
  writeBChan chan (EvSessionInfo info)
  agents <- fetchAgents bridge
  writeBChan chan (EvAgents agents)
  (lspLines, mcpLines) <- fetchServiceStatus bridge
  writeBChan chan (EvServices lspLines mcpLines)
  local <- listLocalSessions
  let summary = find ((== sid) . ssId) local
  -- Keep the per-project index current (title/last-used) while the session runs.
  forM_ summary $ \s -> do
    cwd <- getCurrentDirectory
    recordProjectSession cwd s
  writeBChan chan (EvSessionTitle (ssTitle <$> summary))

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
handleChatWith :: Text -> Text -> EventM ResourceName AppState ()
handleChatWith display sendText = do
  t <- liftIO now
  t0 <- liftIO getCurrentTime
  appendMsg (mkMsg "user" display t)
  modify $ \st -> st { appBusy = True, appStatus = tr (appLang st) "Thinking..."
                     , appTurnStart = Just t0 }
  st <- get
  case appSessionId st of
    Just sid -> liftIO $ setWindowTitle ("● trha · " <> T.take 8 (T.pack sid))
    Nothing  -> return ()

  st <- get
  let bridge = appBridge st
      chan   = appChan st
      model  = appModel st
      provider = appProvider st
      runStepWithTools sid = do
        -- The step reply is the authoritative text; SSE deltas are a live
        -- preview.  Finalizing therefore does not depend on the stream — a
        -- flaky or blocked SSE connection cannot leave the turn busy.
        doneVar <- liftIO newEmptyMVar
        cancel <- subscribeSessionEventsWithTerminal bridge sid (toolSink chan sid)
                    (\t -> writeBChan chan (EvResponse (Right (ChunkDelta t))))
                    (void (tryPutMVar doneVar ()))
                    (writeBChan chan . EvNotice)
        cfg <- liftIO (resolveConfig defaultCLIConfig)
        let eff = if T.toLower (configEffort cfg) == "auto"
                    then Nothing else Just (configEffort cfg)
            mlang = effectiveReasoningLanguage cfg
        result <- sendMessageWithTargetEffort bridge sid provider (Just model) eff mlang sendText
        -- Give the stream a bounded moment to deliver trailing tool events,
        -- then stop it.  The reply itself is already in hand.
        _ <- liftIO $ timeout 250000 (takeMVar doneVar)
        liftIO cancel
        case result of
          Right (c, musage) -> do
            recordChunk sid (Right c)
            case c of
              ChunkDelta reply -> writeBChan chan (EvFinalReply reply)
              _                -> return ()
            -- Always finalize: a missing usage echo must not leave the
            -- spinner running.
            writeBChan chan (EvResponse (Right (ChunkDone (fromMaybe zero musage))))
          Left err -> do
            -- 调度层崩了会让长任务直接断掉：这里尝试拉起一次。会话与
            -- 历史由 scheduler 从 stateDir 恢复，用户重发即可继续。
            case err of
              ConnectionError _ -> do
                started <- ensureBackend (appEffCfg st)
                writeBChan chan . EvResponse . Left $
                  if null started
                    then err
                    else ServerError (tr (appLang st)
                           "The scheduler stopped and has been restarted; resend to continue.")
              _ -> writeBChan chan (EvResponse (Left err))
        refreshSidebar bridge chan sid
      zero = mkUsage 0 0 0
  void $ liftIO $ async $ case appSessionId st of
    Just sid -> do
      recordUser sid display
      runStepWithTools sid
    Nothing -> do
      -- 首次发消息自动建会话时，同样要把当前姿态带上：否则服务端按缺省
      -- read-only 建会话，界面显示 YOLO 但工具仍被拒。
      sessResult <- createSession bridge (smMode <$> appMode st)
      writeBChan chan (EvSession sessResult)
      case sessResult of
        Right sid -> do
          recordSession sid model
          recordUser sid display
          runStepWithTools sid
        Left _ ->
          return ()
  scrollBottom
  where
    -- Record every tool event; completed/failed ones also go to the UI.
    toolSink chan sid ev = case ev of
      Right toolEv -> do
        recordToolEvent sid toolEv
        writeBChan chan (EvTool (Right toolEv))
      Left err -> writeBChan chan (EvTool (Left err))

-- | Numbered preview of the stash (one line per draft).
stashListing :: Lang -> [Text] -> Text
stashListing lang [] = tr lang "stash is empty"
stashListing _ entries =
  T.unlines
    [ T.pack (show i) <> ". " <> takeCells 60 (T.replace "\n" " " e)
    | (i, e) <- zip [(1 :: Int) ..] entries ]

-- | Localised /help text (command list + picker/key hints).
helpTextFor :: Lang -> Text
helpTextFor lang = T.unlines $
  T.lines (registryHelp lang)
    ++ [ ""
       , tr lang "Quick picker:"
       , tr lang "  Type a slash prefix and press Enter to open the command menu;"
       , tr lang "  keep typing to filter, ↑/↓ to move, Enter to run, Esc to close."
       , ""
       , tr lang "Keys:"
       , tr lang "  PgUp / PgDn       Scroll messages"
       , tr lang "  Ctrl+Home / End   Jump to top / bottom"
       , tr lang "  Ctrl+O            Fold / expand thinking and tool cards"
       , tr lang "  Alt+↑ / Alt+↓     Move the tool-card focus"
       , tr lang "  Shift+Tab         Cycle permission posture"
       , tr lang "  Ctrl+Y            Toggle YOLO"
       , tr lang "  Esc Esc           Interrupt the running turn"
       , tr lang "  Ctrl+C            Interrupt · copy selection · clear draft · quit"
       , tr lang "  Ctrl+S            Submit the draft (same as Enter)"
       , tr lang "  Ctrl+Enter        Steer the running turn with the draft"
       , tr lang "  Ctrl+L            Clear the transcript view (history kept)"
       , tr lang "  Alt+V             Paste clipboard text"
       , tr lang "  Ctrl+G            Expand folded pastes"
       , tr lang "  Ctrl+B            Show / hide the sidebar"
       , tr lang "  Ctrl+X            Leader (b/p/m/s/,/?/i)"
       , tr lang "  Ctrl+Q / Ctrl+D   Quit"
       ]


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
openSettingsPanel :: EventM ResourceName AppState ()
openSettingsPanel = do
  st <- get
  let chan = appChan st
      model = appModel st
      mSid = appSessionId st
  cfg <- liftIO (resolveConfig defaultCLIConfig)
  _ <- liftIO $ async $ do
    rows <- collectStatusInfo cfg mSid model
    writeBChan chan (EvStatusInfo rows)
  modify $ \s -> s { appSettings = Just (SettingsPanel TabSettings FocusList 0 "" Nothing Nothing)
                    , appEffCfg = cfg }

-- | Close the /settings panel.
closeSettingsPanel :: EventM ResourceName AppState ()
closeSettingsPanel = modify $ \s -> s { appSettings = Nothing }

-- | Apply one edited value and refresh the snapshot.
applySetting :: Text -> Text -> EventM ResourceName AppState ()
applySetting key raw = do
  lang <- gets appLang
  msg <- liftIO (runSettingsCommand lang (key <> " " <> raw))
  cfg <- liftIO (resolveConfig defaultCLIConfig)
  modify $ \s -> s { appEffCfg = cfg
                    , appSettings = (\p -> p { spEdit = Nothing, spError = Nothing }) <$> appSettings s }
  case msg of
    Just m | any (`T.isPrefixOf` m) ["Error: ", "Unknown", "Value must", "错误：", "未知", "值必须"] ->
      modify $ \s -> s { appSettings = (\p -> p { spError = Just m }) <$> appSettings s }
    Just m ->
      modify $ \s -> s { appSettings = (\p -> p { spError = Just (tr (appLang s) "Saved: " <> m) }) <$> appSettings s }
    Nothing -> return ()

-- | Move the tab by a delta (wraps around the tab list).
moveTab :: Int -> SettingsTab -> SettingsTab
moveTab d t = toEnum (mod (fromEnum t + d) (fromEnum (maxBound :: SettingsTab) + 1))
-- | Keys while the settings panel is open (three-zone focus model, mirroring
-- the reference dialog: tabs -> search -> list -> editing).
handleSettingsKey :: Event -> EventM ResourceName AppState ()
handleSettingsKey (EvKey KEsc []) = do
  st <- get
  case appSettings st of
    -- editing: cancel the edit first
    Just p | Just _ <- spEdit p ->
      modify $ \s -> s { appSettings = Just p { spEdit = Nothing } }
    -- search/list zone with a query: clear it before closing
    Just p | (spFocus p == FocusSearch || spFocus p == FocusList) && not (T.null (spQuery p)) ->
      modify $ \s -> s { appSettings = Just p { spQuery = "", spSel = 0 } }
    _ -> closeSettingsPanel
-- left/right switch the tab from any zone (ignored while editing)
handleSettingsKey (EvKey KLeft []) = do
  st <- get
  if editingNow st then return () else moveTabBy (-1)
handleSettingsKey (EvKey KRight []) = do
  st <- get
  if editingNow st then return () else moveTabBy 1
-- up: search -> tabs ; list top (no query) -> search
handleSettingsKey (EvKey KUp []) = do
  st <- get
  case appSettings st of
    Just p | spFocus p == FocusSearch ->
      modify $ \s -> s { appSettings = Just p { spFocus = FocusTabs } }
    Just p | spFocus p == FocusList && spSel p == 0 && T.null (spQuery p) ->
      modify $ \s -> s { appSettings = Just p { spFocus = FocusSearch } }
    Just p | spFocus p == FocusList -> moveListSel (-1)
    _ -> return ()
-- down: tabs -> search (settings tab) ; search -> list ; list wraps
handleSettingsKey (EvKey KDown []) = do
  st <- get
  case appSettings st of
    Just p | spFocus p == FocusTabs && spTab p == TabSettings ->
      modify $ \s -> s { appSettings = Just p { spFocus = FocusSearch } }
    Just p | spFocus p == FocusSearch ->
      modify $ \s -> s { appSettings = Just p { spFocus = FocusList } }
    Just p | spFocus p == FocusList -> moveListSel 1
    _ -> return ()
handleSettingsKey (EvKey KEnter []) = do
  st <- get
  case appSettings st of
    Nothing -> return ()
    Just p | Just buf <- spEdit p -> do
      let rows = visibleRows st
      case drop (spSel p) rows of
        e : _ -> applySetting (seKey e) buf
        []    -> return ()
    Just p -> case (spTab p, spFocus p) of
      (TabStatus, _)  -> return ()  -- read-only content
      (TabStats, _)   -> return ()
      (TabProviders, FocusList) -> case drop (spSel p) (appProviders st) of
        (p2 : _) -> chooseProvider p2
        []       -> return ()
      (TabSettings, FocusTabs) ->
        modify $ \s -> s { appSettings = Just p { spFocus = FocusSearch } }
      (TabSettings, FocusSearch) ->
        modify $ \s -> s { appSettings = Just p { spFocus = FocusList } }
      (TabSettings, FocusList) -> do
        let rows = visibleRows st
        case drop (spSel p) rows of
          e : _ | seKind e == "bool" -> applySetting (seKey e) (if seVal e == "true" then "false" else "true")
          e : _ | not (null (seOptions e)) ->
            applySetting (seKey e) (nextOption (seOptions e) (seVal e))
          e : _ -> modify $ \s -> s { appSettings = Just p { spEdit = Just (seedEdit e) } }
          []    -> return ()
handleSettingsKey (EvKey (KChar c) []) = do
  st <- get
  let o = fromEnum c
  case appSettings st of
    Just p | Just buf <- spEdit p ->
      modify $ \s -> s { appSettings = Just p { spEdit = Just (buf <> T.singleton c) } }
    Just p | spTab p == TabSettings && spFocus p == FocusSearch, o >= 32 && o < 127 ->
      modify $ \s -> s { appSettings = Just p { spQuery = queryAppend (spQuery p) c, spSel = 0 } }
    Just p | spTab p == TabSettings && spFocus p == FocusList, o >= 32 && o < 127 ->
      modify $ \s -> s { appSettings = Just p { spQuery = queryAppend (spQuery p) c, spSel = 0 } }
    Just p | spTab p == TabProviders && spFocus p == FocusList, o >= 32 && o < 127 ->
      -- Providers 页签的动作键（tui-port L290）：t=思考开关、d=删除确认
      --（复用 DialogProviders 的同款逻辑）。
      case (c, drop (spSel p) (appProviders st)) of
        ('t', (p2 : _)) -> toggleProviderThinking p2
        ('d', (p2 : _)) -> startProviderRemove p2
        _               -> return ()
    _ -> return ()
handleSettingsKey (EvKey KBS []) = do
  st <- get
  case appSettings st of
    Just p | Just buf <- spEdit p ->
      modify $ \s -> s { appSettings = Just p { spEdit = Just (T.dropEnd 1 buf) } }
    Just p | spFocus p == FocusSearch || spFocus p == FocusList ->
      modify $ \s -> s { appSettings = Just p { spQuery = queryDelete (spQuery p), spSel = 0 } }
    _ -> return ()
handleSettingsKey _ = return ()

-- | Is a value edit in progress?
editingNow :: AppState -> Bool
editingNow st = case appSettings st of
  Just p | Just _ <- spEdit p -> True
  _ -> False

-- | Tab-bar switching shared by left/right keys.
moveTabBy :: Int -> EventM ResourceName AppState ()
moveTabBy d = modify $ \s -> s { appSettings = (\p -> p { spTab = moveTab d (spTab p)
                                                           , spSel = 0, spQuery = "", spEdit = Nothing, spError = Nothing }) <$> appSettings s }

-- | Move the list selection by a delta, wrapping around (qwen behaviour:
-- down at the end returns to the top).
moveListSel :: Int -> EventM ResourceName AppState ()
moveListSel d = do
  st <- get
  let n = case appSettings st of
        Just p | spTab p == TabProviders -> length (appProviders st)
        _                                -> length (visibleRows st)
  modify $ \s -> s { appSettings = (\p -> p { spSel = if n <= 0 then 0 else mod (spSel p + d + n) n }) <$> appSettings s }
-- | Initial edit buffer: current value, except secrets which start empty.
seedEdit :: SettingsEntry -> Text
seedEdit e
  | seKey e == "token" = ""
  | otherwise = seVal e

-- | Widget for the settings panel (tab bar + content).
-- | drawSettingsPanel 见 UI.Brick.Draw.Settings（随 settingsRows/visibleRows 一起迁出）。

-- | Clamp a selection into @[0, n-1]@.
clampSel :: Int -> Int -> Int
clampSel n sel
  | n <= 0 = 0
  | otherwise = max 0 (min sel (n - 1))

-- | Two-column rendering of the Status rows (label column padded).
-- | renderStatusRows / computeStatsBlocks / renderStatsBlocks 见 UI.Render.Settings。


-- | Next element in a cycle (wraps to the head); falls back to the head
-- when the current value is not one of the options.
nextOption :: [Text] -> Text -> Text
nextOption opts cur = case break (== cur) opts of
  (_, [])     -> case opts of
    (x : _) -> x
    []      -> ""
  (_, x : rest) -> case rest of
    (nxt : _) -> nxt
    []        -> case opts of
      (h : _) -> h
      []      -> x

-- | Maximum panel row width (kept below the 80-column window).
settingsListWidth :: Int
settingsListWidth = 96

-- | Current git branch name, or a short SHA when detached, or "—".  Asking
-- git itself resolves worktrees, packed refs and detached HEAD correctly;
-- reading @.git/refs/heads/<branch>@ returns the commit SHA, not the name.
gitBranchText :: IO Text
gitBranchText = do
  cwd <- getCurrentDirectory
  (code, out, _) <- runGit ["-C", cwd, "symbolic-ref", "--short", "HEAD"]
  let branch = T.strip (T.pack out)
  if code == ExitSuccess && not (T.null branch)
    then return branch
    else do
      (code2, out2, _) <- runGit ["-C", cwd, "rev-parse", "--short", "HEAD"]
      let short = T.strip (T.pack out2)
      if code2 == ExitSuccess && not (T.null short)
        then return short
        else do
          mhead <- readMaybeFile ".git/HEAD"
          return $ case mhead >>= branchFromHead of
            Just b  -> b
            Nothing -> case mhead of
              Just hd -> T.take 7 (T.strip hd)
              Nothing -> "—"
  where
    runGit args =
      readProcessWithExitCode "git" args "" `catch` \(_ :: IOException) ->
        pure (ExitFailure 1, "", "")
    readMaybeFile fp = do
      r <- try (TIO.readFile fp) :: IO (Either IOException Text)
      return $ case r of
        Left _  -> Nothing
        Right t -> Just t

-- | `+N -M ?K` for the second status line (tracked diff + untracked files).
gitStatText :: IO Text
gitStatText = do
  cwd <- getCurrentDirectory
  (_, ns, _) <- runGit ["-C", cwd, "diff", "--numstat"]
  (_, st, _) <- runGit ["-C", cwd, "status", "--porcelain"]
  let rows = filter (not . T.null) (T.lines (T.pack ns))
      pairs = [ (a, d) | r <- rows
                       , let parts = T.splitOn "\t" r
                       , length parts >= 2
                       , let a = parts !! 0
                       , let d = parts !! 1
                       , a /= "-" ]
      adds = sum [ readI a | (a, _) <- pairs ]
      dels = sum [ readI d | (_, d) <- pairs ]
      -- Only "??" rows are untracked; counting every porcelain row (as this
      -- used to) reported modified files as untracked and inflated the
      -- second status row.
      untracked = length [ r | r <- T.lines (T.pack st), "??" `T.isPrefixOf` r ]
      diff = if adds == 0 && dels == 0 then "" else "+" <> T.pack (show adds) <> " -" <> T.pack (show dels)
      unt = if untracked > 0 then " ?" <> T.pack (show untracked) else ""
  pure (T.strip (diff <> "  " <> unt))
  where
    runGit args =
      readProcessWithExitCode "git" args "" `catch` \(_ :: IOException) ->
        pure (ExitSuccess, "", "")
    readI t = fromMaybe 0 (readMaybe (T.unpack t))

-- | settingsListMax 见 UI.Brick.Draw.Settings。

-- | One task glyph (sidebar and /todo share the vocabulary).
todoGlyph :: TodoStatus -> Text
todoGlyph TodoPending    = "○"
todoGlyph TodoInProgress = "◐"
todoGlyph TodoDone       = "●"

-- | Try the usual clipboard helpers in order; 'False' when none exists.
copyToClipboard :: Text -> IO Bool
copyToClipboard txt = go
  [ ("wl-copy", [])
  , ("xclip", ["-selection", "clipboard"])
  , ("xsel", ["--clipboard", "--input"])
  , ("pbcopy", [])
  ]
  where
    go [] = return False
    go ((cmd, args) : rest) = do
      r <- try (readProcessWithExitCode cmd args (T.unpack txt))
             :: IO (Either IOException (ExitCode, String, String))
      case r of
        Right (ExitSuccess, _, _) -> return True
        _ -> go rest

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
