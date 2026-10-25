{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}

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
import Control.Monad (forM_, void, when)
import Control.Monad.IO.Class (liftIO)
import Core.Types
import Bridge.Scheduler (SchedulerBridge, listPlugins, subscribeSessionEvents, subscribeSessionEventsWith, listSessions, createSession, deleteSession, sendMessage, sendMessageWithUsage, listModels, planStep, approvePlan, denyPlan, submitPlan, decideStep, reportStep)
import Core.Replay (ReplayBlock(..), renderReplay)
import UI.Event
import Core.SessionSummary (SessionSummary(..), pickLocalSession)
import Core.Transcript (listLocalSessions, loadTranscript, recordChunk, recordSession, recordToolEvent, recordUser)
import UI.Commands (runSettingsCommand)
import UI.Commands.Registry (pickerItems, registryHelp)
import UI.SettingsView (SettingsEntry(..), settingsEntries, filterEntries, isOverridden, maskSecret)
import UI.StatusInfo (StatusRow(..), collectStatusInfo)
import UI.StatsView (StatsBlock(..), buildStatsBlocks)
import UI.I18n (Lang(..), parseLang, tr)
import Config.Settings (resolveConfig)
import Data.List (intersperse, find)
import Data.IORef
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isJust, listToMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format (formatTime, defaultTimeLocale)
import Graphics.Vty.Attributes
import Graphics.Vty.Config (defaultConfig)
import Graphics.Vty.CrossPlatform (mkVty)
import Graphics.Vty.Input.Events
import qualified Graphics.Vty as V
import Lens.Micro ((&), (.~), (^.))
import UI.Render.Footer (FooterLive(..), footerMetrics, parseMetrics)
import UI.Render.Footer (footerHints)
import System.Directory (getCurrentDirectory)
import System.IO (hFlush, stdout)
import Control.Exception (IOException, try)
import UI.Render.Markdown (MdBlock(..), MdSpan(..), parseMarkdown)
import UI.InputHistory (HistState(..), emptyHistState, histUp, histDown, histCommit, loadHistory, appendHistory)
import UI.Render.Picker (PickerItem(..), filterItems, maxVisible, moveSelection, queryAppend, queryDelete, windowRange)
import UI.Render.ToolCard (ToolStatus(..), ToolCard(..), ToolFold(..), toggleFold, toolCardView, toolCardLines, toolCardWithStatus)
import UI.Theme (ColorSpec(..), TermColor(..), TermStyle(..), Theme, resolveTheme, themeColors)

-- | Application state
data AppState = AppState
  { appMessages  :: [ChatMessage]
  , appInput     :: Editor Text ResourceName
  , appSessionId :: Maybe SessionId
  , appModel     :: Text
  , appStatus    :: Text
  , appBusy      :: Bool          -- ^ True while awaiting a response
  , appPending   :: Maybe PendingMsg -- ^ Assistant reply being accumulated (streaming)
  , appLastUsage :: Maybe Int     -- ^ Token usage of the last completed reply
  , appHist      :: HistState     -- ^ Input history navigation (REPL-shared file)
  , appPicker    :: Maybe PickerState -- ^ Quick-picker overlay (command menu)
  , appBridge    :: SchedulerBridge
  , appChan      :: BChan AppEvent
  , appLang      :: Lang
  , appSettings  :: Maybe SettingsPanel -- ^ /settings overlay (navigation/edit)
  , appEffCfg    :: CLIConfig           -- ^ effective config snapshot for the panel
  , appSysRows   :: [StatusRow]         -- ^ cached /settings Status rows
  , appMetrics    :: [(Text, Text)]     -- ^ static metric values (workspace/git)
  , appPlan       :: Maybe PlanView     -- ^ live multi-step plan (kernel-owned)
  , appFolds      :: Map.Map Int ToolFold -- ^ tool-card fold states, keyed by msgId
  , appUsage      :: Maybe Usage        -- ^ real usage echo of the last turn
  , appCtxSize    :: Maybe Int          -- ^ context size of the active model
  }

-- | Quick-picker state.  The candidate list is the shared registry
-- ('UI.Commands.Registry.pickerItems'), filtered live by @pQuery@.
data PickerState = PickerState
  { pQuery    :: Text
  , pSelected :: Int
  } deriving (Show)

-- | Chat message with timestamp
data ChatMessage = ChatMessage
  { msgRole    :: Text
  , msgContent :: Text
  , msgTime    :: Text
  , msgTool    :: Maybe ToolCard -- ^ structured tool-card payload
  , msgId      :: Int            -- ^ position-based id (stable: append-only)
  } deriving (Show)

-- | Plain message (no tool payload).
mkMsg :: Text -> Text -> Text -> ChatMessage
mkMsg role content t = ChatMessage role content t Nothing 0

-- | Tool-card message (content holds the pre-rendered collapsed card text
-- for transcript replay; the UI renders the foldable card from the payload).
toolMsg :: Text -> ToolCard -> Text -> ChatMessage
toolMsg role card t =
  ChatMessage role
    (T.unlines (toolCardView FoldCollapsed card)) t (Just card) 0

-- PendingMsg / ToolInv / AppEvent live in UI.Event (pure, unit-tested).

-- | Resource names
data ResourceName
  = MessageArea
  | InputArea
  deriving (Show, Eq, Ord)

-- | Create initial state
initialState :: SchedulerBridge -> BChan AppEvent -> CLIConfig -> AppState
initialState bridge chan cfg = AppState
  { appMessages  = []
  , appInput     = editorText InputArea (Just 6) ""
  , appSessionId = Nothing
  , appModel     = configModel cfg
  , appStatus    = tr lang "Ready"
  , appBusy      = False
  , appPending   = Nothing
  , appLastUsage = Nothing
  , appHist      = emptyHistState
  , appPicker    = Nothing
  , appBridge    = bridge
  , appChan      = chan
  , appLang      = lang
  , appSettings  = Nothing
  , appEffCfg    = cfg
  , appSysRows   = []
  , appMetrics   = []
  , appPlan      = Nothing
  , appFolds     = Map.empty
  , appUsage     = Nothing
  , appCtxSize   = Nothing
  }
  where lang = parseLang (configLang cfg)

-- | Application for a given theme (attribute map follows the palette).
appFor :: Theme -> App AppState AppEvent ResourceName
appFor theme = App
  { appDraw         = drawUI
  , appChooseCursor = showFirstCursor
  , appHandleEvent  = handleEvent
  , appStartEvent   = return ()
  , appAttrMap      = const (themeAttrMap theme)
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

-- | Run the TUI with the named theme (unknown names fall back to default).
runTUI :: SchedulerBridge -> CLIConfig -> IO ()
runTUI bridge cfg = do
  chan <- newBChan 20
  -- static footer metrics are sampled once (workspace path, git branch);
  -- the active model's context size is fetched for the occupancy segment
  _ <- async $ do
    ws <- getCurrentDirectory
    gb <- gitBranchText
    writeBChan chan (EvMetrics [("workspace", T.pack ws), ("git", gb)])
    models <- listModels bridge
    forM_ models $ \ms ->
      forM_ (find (\m -> modelName m == configModel cfg) ms) $ \m ->
        writeBChan chan (EvCtxSize (modelContextSize m))
  let theme = resolveTheme (configTheme cfg)
      mkVty' = mkVty defaultConfig
  vty <- mkVty'
  hist <- loadHistory
  void $ customMain vty mkVty' (Just chan) (appFor theme)
        (initialState bridge chan cfg) { appHist = hist }

--------------------------------------------------------------------------------
-- Drawing
--------------------------------------------------------------------------------

drawUI :: AppState -> [Widget ResourceName]
drawUI st =
  case appSettings st of
    -- /settings takes over the whole screen (qwen-style dialog): the tab
    -- bar sits at the top and the content fills the terminal.
    Just _  -> [ drawSettingsPanel st ]
    Nothing ->
      [ vBox
          [ drawHeader (appLang st)
          , drawMessages st
          , maybe emptyWidget drawPlanCard (appPlan st)
          , maybe emptyWidget (drawPickerWidget st) (appPicker st)
          , drawInput st
          , drawStatus st
          ]
      ]

drawHeader :: Lang -> Widget ResourceName
drawHeader lang =
  withAttr (attrName "header") $
    padLeftRight 1 $
      hBox [ str " trha ", str (T.unpack (tr lang "— agent harness")) ]

-- | Quick-picker overlay: filtered command list with a live query row.
drawPickerWidget :: AppState -> PickerState -> Widget ResourceName
drawPickerWidget st ps =
  withAttr (attrName "border") $
    borderWithLabel (withAttr (attrName "title") $ str (T.unpack (tr lang " Commands "))) $
      vBox (rows ++ [queryRow])
  where
    lang = appLang st
    matches = filterItems (pQuery ps) (pickerItems lang)
    n       = length matches
    sel     = pSelected ps
    (start, end) = windowRange n sel maxVisible
    rows = [ pickerRow idx sel it
           | (idx, it) <- zip [start ..] (drop start (take (end + 1) matches))
           , idx <= end ]
    queryRow = padLeftRight 1 $ hBox
      [ withAttr (attrName "input") $ str ("> " ++ T.unpack (pQuery ps))
      , withAttr (attrName "status") $ str (T.unpack (tr lang "   ↑/↓ move · Enter run · Esc close"))
      ]

    pickerRow :: Int -> Int -> PickerItem -> Widget ResourceName
    pickerRow idx cur it =
      padLeftRight 1 $ hBox
        [ withAttr markerAttr $ str marker
        , str " "
        , withAttr (attrName "title") $ str (T.unpack (piId it))
        , withAttr (attrName "timestamp") $ str $ "  " ++ T.unpack (T.take 44 (piDesc it))
        ]
      where
        marker | idx == cur = "▸ "
               | otherwise  = "  "
        markerAttr | idx == cur = attrName "tool"
                   | otherwise  = attrName "timestamp"

statusLine :: AppState -> Text
statusLine st = T.unlines
  [ tr lang "Status:"
  , tr lang "  Session: " <> maybe (tr lang "none") T.pack (appSessionId st)
  , tr lang "  Model: " <> appModel st
  , "  " <> appStatus st
  ]
  where lang = appLang st

-- | Resume a local session: replay its transcript into the message area
-- and make it the active session.
resumeSession :: Text -> EventM ResourceName AppState ()
resumeSession selText = do
  lang <- gets appLang
  t <- liftIO now
  local <- liftIO listLocalSessions
  case pickLocalSession (T.unpack selText) local of
    Nothing ->
      appendMsg (mkMsg "system" (tr lang "No local session matches: " <> selText) t)
    Just s -> do
      events <- liftIO (loadTranscript (ssId s))
      let msgs = blocksToMessages (renderReplay events)
      modify $ \st -> st { appMessages = msgs
                         , appSessionId = Just (ssId s)
                         , appStatus = tr (appLang st) "Resumed " <> T.pack (ssId s)
                         , appBusy = False
                         , appPending = Nothing }
      when (null msgs) $
        appendMsg (mkMsg "system" (tr lang "Session " <> T.pack (ssId s) <> tr lang " has an empty transcript.") t)
      appendMsg (mkMsg "system" (tr lang "Note: continuing needs the session on the orchestration side.") t)
      scrollBottom

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
        toolMsg "tool" (ToolCard name args Nothing Nothing []) (maybe "" id (rbTime b))
      Nothing           -> mkMsg (rbRole b) (rbContent b) (maybe "" id (rbTime b))

drawMessages :: AppState -> Widget ResourceName
drawMessages st =
  withAttr (attrName "border") $
    borderWithLabel (withAttr (attrName "title") $ str " Messages ") $
      viewport MessageArea Vertical $
        vBox $
          case (appMessages st, appPending st) of
            ([], Nothing) ->
              [ padAll 1 $ withAttr (attrName "timestamp") $
                  strWrap "No messages yet. Type something and press Enter, or /help for commands." ]
            _ -> [ drawMessage cfg (foldOf m) m | m <- appMessages st ]
                   ++ maybe [] (pure . drawPending cfg) (appPending st)
  where
    cfg = appEffCfg st
    foldOf m = fromMaybe FoldCollapsed (Map.lookup (msgId m) (appFolds st))

-- | Display style for a message role: (attribute, bracket label).
roleDisplay :: Text -> (AttrName, Text)
roleDisplay role = case role of
  "user"      -> (attrName "user", role)
  "assistant" -> (attrName "assistant", role)
  "tool"      -> (attrName "tool", role)
  "plan"      -> (attrName "plan", role)
  "system"    -> (attrName "system", role)
  "error"     -> (attrName "error", role)
  _           -> (attrName "header", role)

-- | Header row shared by messages and the streaming block:
-- @[role] timestamp@.
messageHeader :: Bool -> Text -> Text -> Widget ResourceName
messageHeader showTs role time =
  hBox (roleW : [timeW | showTs])
  where
    sty = roleDisplay role
    roleW = withAttr (fst sty) $ str $ "[" ++ T.unpack (snd sty) ++ "]"
    timeW = hBox [str " ", withAttr (attrName "timestamp") (str (T.unpack time))]

-- | Body of a message: a tool-invocation card, an assistant reply run
-- through the Markdown renderer, or plain wrapped text.
messageBody :: Bool -> Text -> Text -> Maybe ToolCard -> ToolFold -> Widget ResourceName
messageBody md role content tool fold =
  case tool of
    Just card ->
      padLeft (Pad 2) $
        withAttr (attrName "tool") $
          vBox [ str (T.unpack l) | l <- toolCardView fold card ]
    Nothing
      | role == "assistant" && md ->
          padLeft (Pad 2) $
            withAttr (attrName "assistant") $
              vBox (renderBlocks (parseMarkdown content))
      | role == "assistant" ->
          padLeft (Pad 2) $
            withAttr (attrName "assistant") $ strWrap (T.unpack content)
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
          padLeft (Pad 2) $ strWrap (T.unpack content)

drawMessage :: CLIConfig -> ToolFold -> ChatMessage -> Widget ResourceName
drawMessage cfg fold msg =
  padLeftRight 1 $
    padTopBottom 1 $
      vBox
        [ messageHeader (configTimestamps cfg) (msgRole msg) (msgTime msg)
        , messageBody (configMarkdown cfg) (msgRole msg) (msgContent msg) (msgTool msg) fold
        ]

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

-- | A word-wrapping token: one word or space-run, carrying the attribute
-- name of the span it came from.
data SpanTok = SpanTok { tokAttr :: String, tokText :: Text }

spanToks :: MdSpan -> [SpanTok]
spanToks (MdPlain t)   = spanToksWith "" t
spanToks (MdBold t)    = spanToksWith "mdBold" t
spanToks (MdCode t)    = spanToksWith "mdCode" t

spanToksWith :: String -> Text -> [SpanTok]
spanToksWith attr tt = [ SpanTok attr u | u <- runs tt ]
  where
    runs t
      | T.null t = []
      | otherwise =
          let (gap, rest) = T.span (== ' ') t
          in if T.null gap
               then let (w, rest') = T.span (/= ' ') t
                    in w : runs rest'
               else gap : runs rest

-- | Greedy word fill at @width@ columns (measured the same way vty
-- measures: per-character wcwidth).  Space runs are held pending and only
-- committed when a word follows, so line breaks never carry trailing
-- spaces; words wider than a whole line are hard-split by character.
fillLines :: Int -> [SpanTok] -> [[SpanTok]]
fillLines width = go [] [] 0
  where
    tokW = V.wctwidth . tokText

    go line pends used [] = [ reverse line | not (null line) ]
    go line pends used (t : rest)
      | T.all (== ' ') (tokText t) = go line (pends ++ [t]) used rest
      | used + pendingW + tokW t <= width =
          go (reverse pends ++ t : line) [] (used + pendingW + tokW t) rest
      | null line && null pends && tokW t > width =
          let (chunk, rest') = splitAtWidth width (tokText t)
          in  [ t { tokText = chunk } ]
                : fillLines width
                    ([ t { tokText = rest' } | not (T.null rest') ] ++ rest)
      | otherwise = go [] [] 0 (t : rest)
      where pendingW = sum (map tokW pends)

-- | Split the longest prefix whose display width fits @w@ columns.  The
-- first character is always taken (degenerate 1-column terminals), so the
-- result always makes progress.
splitAtWidth :: Int -> Text -> (Text, Text)
splitAtWidth w = go 0 ""
  where
    go used acc tt = case T.uncons tt of
      Nothing -> (T.reverse acc, "")
      Just (ch, rest)
        | used > 0 && used + V.safeWcwidth ch > w -> (T.reverse acc, tt)
        | otherwise -> go (used + V.safeWcwidth ch) (T.cons ch acc) rest

-- | Render the assistant reply currently being accumulated.
-- A blinking cursor suffix signals that the stream is still open.
drawPending :: CLIConfig -> PendingMsg -> Widget ResourceName
drawPending cfg pm =
  padLeftRight 1 $
    padTopBottom 1 $
      vBox
        [ messageHeader (configTimestamps cfg) "assistant" (pmStart pm)
        , messageBody (configMarkdown cfg) "assistant" (pmContent pm <> "▍") Nothing FoldCollapsed
        ]

drawInput :: AppState -> Widget ResourceName
drawInput st =
  withAttr (attrName "border") $
    borderWithLabel busyLabel $
      withAttr (attrName "input") $
        renderEditor (str . T.unpack . T.unlines) True (appInput st)
  where
    -- No timer thread: streaming deltas drive redraws, so the frame index
    -- derives from the accumulated length — it animates exactly while the
    -- reply is actually moving (a frozen spinner honestly shows a stall).
    awaitingStep = case appPlan st of
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

-- | Braille spinner frames (10-step cycle). Pure so it is trivially testable.
spinnerFrame :: Int -> Text
spinnerFrame i = frames !! (i `mod` length frames)
  where frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

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

drawStatus :: AppState -> Widget ResourceName
drawStatus st =
  withAttr (attrName "status") $
    padLeftRight 1 $
      hBox (intersperse (str "  │  ")
        (map (str . T.unpack) metricSegs
          ++ [str (T.unpack footerHints) | configHints (appEffCfg st)]))
  where
    live = FooterLive (appModel st) (fmap T.pack (appSessionId st)) (appStatus st)
                      (appLastUsage st) (messageChars st)
                      (appUsage st) (appCtxSize st)
    metricSegs = footerMetrics (appLang st) (parseMetrics (configMetrics (appEffCfg st))) live (appMetrics st)
    messageChars st2 = sum (map (T.length . msgContent) (appMessages st2))

--------------------------------------------------------------------------------
-- Event handling
--------------------------------------------------------------------------------

now :: IO Text
now = T.pack . formatTime defaultTimeLocale "%H:%M:%S" <$> getCurrentTime

-- | Append a message, stamping it with the next position-based id.
appendMsg :: ChatMessage -> EventM ResourceName AppState ()
appendMsg msg = modify $ \st ->
  st { appMessages = appMessages st ++ [msg { msgId = length (appMessages st) }] }

scrollBottom :: EventM ResourceName AppState ()
scrollBottom = vScrollToEnd (viewportScroll MessageArea)

handleEvent :: BrickEvent ResourceName AppEvent -> EventM ResourceName AppState ()
handleEvent (AppEvent ev) = handleAppEvent ev
handleEvent (VtyEvent (EvKey (KChar 'q') [MCtrl])) = halt
handleEvent (VtyEvent (EvKey (KChar 'c') [MCtrl])) = halt
handleEvent (VtyEvent ev) = do
  st <- get
  case appSettings st of
    Just _  -> handleSettingsKey ev
    Nothing -> case appPicker st of
      Just _  -> handlePickerKey ev
      Nothing -> handleChatKey ev
handleEvent _ = return ()

-- | Keys while the quick picker is open.
handlePickerKey :: Event -> EventM ResourceName AppState ()
handlePickerKey (EvKey KUp [])       = movePickerSel (-1)
handlePickerKey (EvKey KDown [])     = movePickerSel 1
handlePickerKey (EvKey (KChar 'p') [MCtrl]) = movePickerSel (-1)
handlePickerKey (EvKey (KChar 'n') [MCtrl]) = movePickerSel 1
handlePickerKey (EvKey KEnter [])    = pickerEnter
handlePickerKey (EvKey KEsc [])      = modify $ \s -> s { appPicker = Nothing }
handlePickerKey (EvKey KBS [])       = do
  modify $ \s -> s { appPicker = (\ps -> ps { pQuery = queryDelete (pQuery ps), pSelected = 0 }) <$> appPicker s }
  scrollBottom
handlePickerKey (EvKey (KChar c) [])
  | let o = fromEnum c in o >= 32 && o < 127 = do
      modify $ \s -> s { appPicker = (\ps -> ps { pQuery = queryAppend (pQuery ps) c, pSelected = 0 }) <$> appPicker s }
      scrollBottom
handlePickerKey _ = return ()

-- | Move the picker selection, clamping to the current match list.
movePickerSel :: Int -> EventM ResourceName AppState ()
movePickerSel delta = do
  st <- get
  case appPicker st of
    Nothing -> return ()
    Just ps -> do
      let n = length (filterItems (pQuery ps) (pickerItems (appLang st)))
      modify $ \s -> s { appPicker = Just ps { pSelected = moveSelection delta (pSelected ps) n } }

-- | Run the command under the picker cursor.
pickerEnter :: EventM ResourceName AppState ()
pickerEnter = do
  st <- get
  case appPicker st of
    Nothing -> return ()
    Just ps -> do
      let matches = filterItems (pQuery ps) (pickerItems (appLang st))
      modify $ \s -> s { appPicker = Nothing }
      case drop (pSelected ps) matches of
        item : _ -> handleSlash (piId item)
        []       -> return ()

-- | Keys in the normal chat view.
handleChatKey :: Event -> EventM ResourceName AppState ()
handleChatKey (EvKey KPageUp []) =
  vScrollBy (viewportScroll MessageArea) (-10)
handleChatKey (EvKey KPageDown []) =
  vScrollBy (viewportScroll MessageArea) 10
-- | ctrl+o expands/collapses the most recent tool card.
handleChatKey (EvKey (KChar 'o') [MCtrl]) = toggleRecentFold
handleChatKey (EvKey (KChar 'g') []) =
  vScrollToBeginning (viewportScroll MessageArea)
handleChatKey (EvKey (KChar 'G') []) =
  scrollBottom
handleChatKey (EvKey KEnter []) = do
  st <- get
  let input = T.strip $ T.unlines $ getEditContents $ appInput st
  if not (T.null input) && not (appBusy st)
    then do
      liftIO (appendHistory input)
      modify $ \s -> s { appInput = editorText InputArea (Just 6) ""
                       , appHist = histCommit input (appHist s) }
      handleSubmit input
    else when (T.null input && not (appBusy st)) toggleRecentFold
-- | alt+enter inserts a newline: the editor only breaks lines on a plain
-- KEnter, so feed it one directly (this skips the submit intercept).
handleChatKey (EvKey KEnter [MAlt]) = editDefaultKey (EvKey KEnter [])
-- | ↑ recalls history when the cursor is on the first line; inside the
-- input it moves the cursor up one line.
handleChatKey (EvKey KUp []) = do
  st <- get
  let cur = T.unlines (getEditContents (appInput st))
  case histUp cur (appHist st) of
    Just (h', entry) | cursorRow (appInput st) == 0 ->
      put st { appHist = h', appInput = editorText InputArea (Just 6) entry }
    _ -> editDefaultKey (EvKey KUp [])
-- | ↓ walks history forward (or restores the draft) when the cursor is on
-- the last line; inside the input it moves the cursor down one line.
handleChatKey (EvKey KDown []) = do
  st <- get
  let rows = max 1 (length (getEditContents (appInput st)))
  if cursorRow (appInput st) == rows - 1
    then case histDown (appHist st) of
      Just (h', entry) ->
        put st { appHist = h', appInput = editorText InputArea (Just 6) entry }
      Nothing -> editDefaultKey (EvKey KDown [])
    else editDefaultKey (EvKey KDown [])
-- | A leading @/@ on an empty input opens the quick-picker (command menu);
-- any other @/@ is typed into the editor as plain text.
handleChatKey (EvKey (KChar '/') []) = do
  st <- get
  let input = T.strip $ T.unlines $ getEditContents $ appInput st
  if T.null input
    then modify $ \s -> s { appPicker = Just (PickerState "/" 0) }
    else do
      newInput <- nestEventM' (appInput st) $ handleEditorEvent (VtyEvent (EvKey (KChar '/') []))
      put st { appInput = newInput }
handleChatKey ev = editDefaultKey ev

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
toggleRecentFold :: EventM ResourceName AppState ()
toggleRecentFold = do
  st <- get
  let mid = listToMaybe [msgId m | m <- reverse (appMessages st), isJust (msgTool m)]
  forM_ mid $ \i -> modify $ \s ->
    s { appFolds = Map.alter (Just . toggleFold . fromMaybe FoldCollapsed) i (appFolds s) }
  scrollBottom

-- | Ensure a streaming block is open for the current assistant reply.
ensurePending :: EventM ResourceName AppState ()
ensurePending = do
  st <- get
  case appPending st of
    Just _ -> return ()
    Nothing -> do
      t <- liftIO now
      modify $ \s -> s { appPending = Just (PendingMsg "" [] t) }

-- | Append a text delta to the open assistant block.
appendDelta :: Text -> EventM ResourceName AppState ()
appendDelta text = do
  ensurePending
  modify $ \s -> s { appPending = (\pm -> pm { pmContent = pmContent pm <> text }) <$> appPending s }

-- | Record a tool invocation in the open block.
addToolLine :: ToolName -> [Text] -> EventM ResourceName AppState ()
addToolLine name args = do
  ensurePending
  let inv = ToolInv name args
  modify $ \s -> s { appPending = (\pm -> pm { pmTools = inv : pmTools pm }) <$> appPending s }

-- | Close the streaming block and persist it as chat messages.
flushPending :: EventM ResourceName AppState ()
flushPending = do
  st <- get
  case appPending st of
    Nothing -> return ()
    Just pm -> do
      let base = length (appMessages st)
          stampedFrom base0 ms = zipWith (\i m -> m { msgId = base0 + i }) [0 ..] ms
          toolMsgs = [ toolMsg "tool" (ToolCard (tiName inv) (tiArgs inv) Nothing Nothing []) (pmStart pm)
                     | inv <- reverse (pmTools pm) ]
          textMsgs = [ mkMsg "assistant" (T.strip (pmContent pm)) (pmStart pm)
                     | not (T.null (T.strip (pmContent pm))) ]
      modify $ \s -> s { appMessages = appMessages s
                                      ++ stampedFrom base toolMsgs
                                      ++ stampedFrom (base + length toolMsgs) textMsgs
                       , appPending = Nothing
                       , appBusy = False
                       , appStatus = tr (appLang s) "Ready" }

-- | Async events from background workers
handleAppEvent :: AppEvent -> EventM ResourceName AppState ()
handleAppEvent (EvSession result) = do
  case result of
    Right sid -> do
      -- Auto-created sessions are recorded silently so that the system
      -- message does not interleave between the user message and the reply.
      modify $ \st -> st { appSessionId = Just sid, appStatus = tr (appLang st) "Ready" }
    Left err -> do
      lang <- gets appLang
      t <- liftIO now
      appendMsg (mkMsg "error" (tr lang "Session failed: " <> T.pack (show err)) t)
      modify $ \st -> st { appStatus = tr (appLang st) "Error", appBusy = False }
  scrollBottom
handleAppEvent (EvResponse result) = case result of
  Right chunk -> case chunk of
    ChunkDelta text    -> appendDelta text >> scrollBottom
    ChunkToolCall n as -> addToolLine n as >> scrollBottom
    ChunkDone usage    -> do
      flushPending
      bell <- gets (configBell . appEffCfg)
      when bell $ liftIO (putStr "\a" >> hFlush stdout)
      let real = usageTotalTokens usage > 0
      modify $ \s -> s { appLastUsage = Just (usageTotalTokens usage)
                       , appUsage = if real then Just usage else appUsage s }
      scrollBottom
  Left err -> do
    flushPending -- keep whatever partial content already arrived
    t <- liftIO now
    appendMsg (mkMsg "error" ("Error: " <> T.pack (show err)) t)
    modify $ \st -> st { appStatus = tr (appLang st) "Error", appBusy = False }
    scrollBottom
handleAppEvent (EvSessions result) = do
  lang <- gets appLang
  t <- liftIO now
  let body = case result of
        Right []  -> tr lang "No sessions."
        Right sids -> (tr lang "Sessions:" <> "\n") <> T.unlines (map (\s -> "  • " <> T.pack s) sids)
        Left err   -> tr lang "Error: " <> T.pack (show err)
  appendMsg (mkMsg "system" body t)
  scrollBottom
handleAppEvent (EvModels result) = do
  lang <- gets appLang
  t <- liftIO now
  let body = case result of
        Right []    -> tr lang "No models available."
        Right ms    -> (tr lang "Models:" <> "\n") <> T.unlines
                         (map (\m -> "  • " <> modelName m <> " — " <> modelDescription m) ms)
        Left err    -> tr lang "Error: " <> T.pack (show err)
  appendMsg (mkMsg "system" body t)
  scrollBottom
handleAppEvent (EvDeleted sid) = do
  lang <- gets appLang
  t <- liftIO now
  appendMsg (mkMsg "system" (tr lang "Deleted session: " <> T.pack sid) t)
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
      modify $ \st -> st { appStatus = tr (appLang st) "Ready", appBusy = False }
    Right PlanDenied ->
      appendMsg (mkMsg "system" (tr lang "Plan denied.") t)
    Left err -> do
      appendMsg (mkMsg "error" (T.pack (show err)) t)
      modify $ \st -> st { appStatus = tr (appLang st) "Error", appBusy = False }
  scrollBottom
handleAppEvent (EvStatusInfo rows) = do
  modify $ \s -> s { appSysRows = rows }
handleAppEvent (EvMetrics rows) = do
  modify $ \s -> s { appMetrics = rows }
handleAppEvent (EvTool result) = do
  lang <- gets appLang
  t <- liftIO now
  case result of
    Right ev -> do
      -- running events only update the status line; completed events
      -- become tool cards
      modify $ \st -> st { appStatus = tr (appLang st) "tool: " <> T.pack (teName ev) <> " " <> tr (appLang st) (statusTagOf (teStatus ev)) }
      case teStatus ev of
        ToolRunRunning -> return ()
        _              -> appendMsg (toolCardMsg ev t)
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

-- | Tool-card message from a completed lifecycle event (with output
-- preview lines from the kernel tail).
toolCardMsg :: ToolEvent -> Text -> ChatMessage
toolCardMsg ev t = toolMsg "tool" card t
  where
    card = ToolCard (teName ev) (teArgs ev)
                    (Just (toCardStatus (teStatus ev))) (teDurationMs ev)
                    (maybe [] T.lines (teOutput ev))

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
  T.unlines (toolCardWithStatus (T.pack (teName ev)) (teArgs ev)
              (toCardStatus (teStatus ev)) (teDurationMs ev))

-- | Map the wire status to the card status type.
toCardStatus :: ToolRunStatus -> ToolStatus
toCardStatus s = case s of
  ToolRunRunning   -> ToolRunning
  ToolRunSucceeded -> ToolSucceeded
  ToolRunFailed e  -> ToolFailed e

-- | Dispatch submitted input: open the quick picker when a slash prefix is
-- ambiguous, otherwise run the command / send the chat message.
handleSubmit :: Text -> EventM ResourceName AppState ()
handleSubmit input = do
  st <- get
  if "/" `T.isPrefixOf` input
    then case filterItems input (pickerItems (appLang st)) of
      []  -> handleSlash input  -- unknown or parameterised command typed in full
      [_] -> handleSlash input  -- unique match: run it directly
      _   -> modify $ \s -> s { appPicker = Just (PickerState input 0) }
    else handleChat input

handleSlash :: Text -> EventM ResourceName AppState ()
handleSlash input = do
  t <- liftIO now
  st <- get
  let cmd = T.toLower input
      bridge = appBridge st
      chan   = appChan st
      lang   = appLang st
  case cmd of
    "/help" ->
      appendMsg (mkMsg "system" (helpTextFor (appLang st)) t)
    "/clear" ->
      modify $ \s -> s { appMessages = [], appFolds = Map.empty }
    "/new" -> do
      modify $ \s -> s { appBusy = True, appStatus = "Creating session..." }
      void $ liftIO $ async $
        createSession bridge >>= writeBChan chan . EvSession
    "/settings"
      | T.null (T.strip (T.drop 9 input)) -> openSettingsPanel
      | otherwise -> do
          let arg = T.strip (T.drop 9 input)
          msg <- liftIO (runSettingsCommand lang arg)
          forM_ msg $ \m -> appendMsg (mkMsg "system" m t)
          scrollBottom
    "/sessions" ->
      void $ liftIO $ async $
        listSessions bridge >>= writeBChan chan . EvSessions
    "/models" ->
      void $ liftIO $ async $
        listModels bridge >>= writeBChan chan . EvModels
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
      case cur of
        Nothing -> appendMsg (mkMsg "system" "No session yet — use /new or send a message first." t)
        Just sid -> do
          void $ liftIO $ async $ do
            r <- denyPlan bridge sid
            writeBChan chan (EvVerdict r)
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
      local <- liftIO listLocalSessions
      if null local
        then appendMsg (mkMsg "system" (tr lang "No local sessions found. Run a conversation first.") t)
        else do
          appendMsg (mkMsg "system" ("Local sessions:\n" <> T.unlines (localSessionLines (appLang st) local)) t)
          appendMsg (mkMsg "system" (tr lang "Resume with /resume <number-or-id>.") t)
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
          appendMsg (mkMsg "system" ("Current model: " <> appModel st) t)
      | "/model " `T.isPrefixOf` cmd -> do
          let model = T.strip (T.drop 7 input)
          modify $ \s -> s { appModel = model }
          appendMsg (mkMsg "system" ("Model set: " <> model) t)
      | "/delete " `T.isPrefixOf` cmd -> do
          let sid = T.unpack (T.strip (T.drop 8 input))
          if null sid
            then appendMsg (mkMsg "system" "Usage: /delete <session-id>" t)
            else do
              cur <- gets appSessionId
              when (cur == Just sid) $
                modify $ \s -> s { appSessionId = Nothing }
              void $ liftIO $ async $ do
                _ <- deleteSession bridge sid
                writeBChan chan (EvDeleted sid)
      | cmd `elem` ["/skip", "/reject", "/abandon"] -> do
          cur <- gets appSessionId
          case cur of
            Nothing ->
              appendMsg (mkMsg "system" "No session yet — use /new or send a message first." t)
            Just sid -> do
              let action = T.drop 1 cmd
              modify $ \s2 -> s2 { appBusy = True, appStatus = "Plan decision..." }
              void $ liftIO $ async $ do
                r <- decideStep bridge sid action
                writeBChan chan (EvPlanState (fmap ((, Nothing)) r))
      | otherwise ->
          appendMsg (mkMsg "system" (tr lang "Unknown command: " <> input <> tr lang " — try /help") t)
  scrollBottom

-- | Send a chat message: create session lazily, send async, never block UI.
-- While the step runs, tool lifecycle events arrive over SSE; they are
-- recorded to the transcript and surfaced through 'EvTool'.
handleChat :: Text -> EventM ResourceName AppState ()
handleChat input = do
  t <- liftIO now
  appendMsg (mkMsg "user" input t)
  modify $ \st -> st { appBusy = True, appStatus = tr (appLang st) "Thinking..." }

  st <- get
  let bridge = appBridge st
      chan   = appChan st
      model  = appModel st
      runStepWithTools sid = do
        -- Streaming contract (M0): when the scheduler emits text deltas the
        -- deltas are authoritative and the synchronous reply is only the
        -- terminal signal — emitting its text too would duplicate the stream.
        -- Kernels without SSE deltas fall back to the whole reply in one chunk
        -- (the pre-M0 behaviour). The transcript keeps one accumulated row
        -- either way.
        accRef     <- liftIO (newIORef T.empty)
        deltasRef  <- liftIO (newIORef False)
        cancel <- subscribeSessionEventsWith bridge sid (toolSink chan sid) $ \t -> do
          liftIO $ atomicModifyIORef' deltasRef (const (True, ()))
          liftIO $ atomicModifyIORef' accRef (\acc -> (acc <> t, ()))
          writeBChan chan (EvResponse (Right (ChunkDelta t)))
        result <- sendMessageWithUsage bridge sid input
        let (chunk, musage) = case result of
              Right (c, u) -> (Right c, u)
              Left e       -> (Left e, Nothing)
        sawDeltas <- liftIO (readIORef deltasRef)
        case (sawDeltas, chunk) of
          (True, _) -> do
            acc <- liftIO (readIORef accRef)
            recordChunk sid (Right (ChunkDelta acc))
            -- real usage when the kernel echoes it (turn out + cumulative)
            writeBChan chan (EvResponse (Right (ChunkDone (fromMaybe zero musage))))
          (False, c) -> do
            recordChunk sid c
            writeBChan chan (EvResponse c)
            forM_ musage $ \u ->
              writeBChan chan (EvResponse (Right (ChunkDone u)))
        -- drain window: let trailing SSE events (e.g. the final tool
        -- status) arrive before tearing the stream down
        liftIO $ threadDelay 100000
        cancel
      zero = Usage 0 0 0
  void $ liftIO $ async $ case appSessionId st of
    Just sid -> do
      recordUser sid input
      runStepWithTools sid
    Nothing -> do
      sessResult <- createSession bridge
      writeBChan chan (EvSession sessResult)
      case sessResult of
        Right sid -> do
          recordSession sid model
          recordUser sid input
          runStepWithTools sid
        Left _ ->
          return ()
  scrollBottom
  where
    -- Record every tool event; completed/failed ones also go to the UI.
    toolSink chan sid ev = case ev of
      Right toolEv -> do
        recordToolEvent sid toolEv
        case teStatus toolEv of
          ToolRunRunning -> return ()
          _              -> writeBChan chan (EvTool (Right toolEv))
      Left err -> writeBChan chan (EvTool (Left err))

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
       , tr lang "  g / G             Jump to top / bottom"
       , tr lang "  Ctrl+Q            Quit"
       ]


-- /settings panel -- port of the qwen-code SettingsDialog interaction:
-- a tab bar (Settings / Status / Stats) plus a focus model where the
-- keyboard moves between the tab bar and the list (and into value editing).
--   keys:  left/right  switch tab (any focus)
--          up          list top -> tab bar    down: tab bar -> list
--          enter       tab bar: activate list | list: edit/toggle value
--          type        filter list (search)  esc: close / cancel edit

data SettingsTab
  = TabSettings
  | TabStatus
  | TabStats
  deriving (Show, Eq, Enum, Bounded)

data SettingsFocus
  = FocusTabs
  | FocusSearch
  | FocusList
  deriving (Show, Eq)

-- | Panel state: active tab, focus region, list selection/query/edit.
data SettingsPanel = SettingsPanel
  { spTab   :: SettingsTab
  , spFocus :: SettingsFocus
  , spSel   :: Int            -- ^ selected index within the filtered rows
  , spQuery :: Text           -- ^ live filter (typed while the list is focused)
  , spEdit  :: Maybe Text     -- ^ Just buffer while editing a text value
  , spError :: Maybe Text     -- ^ last apply error (shown under the list)
  } deriving (Show)

tabList :: [SettingsTab]
tabList = [minBound .. maxBound]

tabLabel :: Lang -> SettingsTab -> Text
tabLabel lang t = tr lang (case t of
  TabSettings -> "Settings"
  TabStatus   -> "Status"
  TabStats    -> "Stats")

-- | Rows for the current effective config in the active language.
settingsRows :: AppState -> [SettingsEntry]
settingsRows st = settingsEntries (appLang st) (appEffCfg st)

-- | Filtered rows currently shown in the settings tab.
visibleRows :: AppState -> [SettingsEntry]
visibleRows st = filterEntries q (settingsRows st)
  where
    q = maybe "" spQuery (appSettings st)

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
  let n = length (visibleRows st)
  modify $ \s -> s { appSettings = (\p -> p { spSel = if n <= 0 then 0 else mod (spSel p + d + n) n }) <$> appSettings s }
-- | Initial edit buffer: current value, except secrets which start empty.
seedEdit :: SettingsEntry -> Text
seedEdit e
  | seKey e == "token" = ""
  | otherwise = seVal e

-- | Widget for the settings panel (tab bar + content).
drawSettingsPanel :: AppState -> Widget ResourceName
drawSettingsPanel st =
  withAttr (attrName "border") $
    borderWithLabel (withAttr (attrName "title") $ str (T.unpack (tr lang " settings "))) $
      vBox (tabBarRow : contentRows ++ [fill ' '])
  where
    lang = appLang st
    p = case appSettings st of
      Just x  -> x
      Nothing -> SettingsPanel TabSettings FocusList 0 "" Nothing Nothing
    -- make one row span the full dialog width (fill absorbs the rest)
    fullRow w = vLimit 1 $ hBox [padLeftRight 1 w, fill ' ']
    fullRowAny w = hBox [padLeftRight 1 w, fill ' '] -- single line vs. multi-line content
    tabBarRow = fullRow $ hBox
      [ hBox (map tabWidget tabList)
      , str "  "
      , withAttr (attrName "status") (str (T.unpack hintText))
      ]
    tabWidget t =
      let active = spTab p == t
          label = " " <> tabLabel lang t <> " "
          attr  = if active then attrName "tool" else attrName "timestamp"
      in withAttr attr (str (T.unpack label))
    hintText = case spFocus p of
      FocusTabs -> tr lang "←/→ to switch tabs"
      FocusSearch -> tr lang "↑ tabs · ↓ list · type to filter"
      FocusList -> case spEdit p of
        Just _  -> tr lang "Enter save · Esc cancel"
        Nothing -> tr lang "↑/↓ move · Enter edit · Esc close"
          <> "  " <> tr lang "←/→ to switch tabs"
    contentRows = case spTab p of
      TabSettings -> settingsListRows
      TabStatus   -> [fullRowAny (renderStatusRows lang (appSysRows st))]
      TabStats    -> [fullRowAny (vLimit 22 (renderStatsBlocks lang (computeStatsBlocks st)))]
    settingsListRows = fullRow (searchRow st p) : map fullRow rowsShown ++ [fullRow descRow, fullRow statusRow]
    searchRow st2 sp =
      let q = spQuery sp
          n = length (filterEntries q (settingsRows st2))
          left = if T.null q then tr (appLang st2) "Settings" else tr (appLang st2) "Search: " <> q
      in hBox
        [ withAttr (attrName "input") $ str (T.unpack left)
        , str "   "
        , withAttr (attrName "status") $ str (T.unpack (searchRight sp n))
        ]
    searchRight sp n = case spEdit sp of
      Just buf  -> tr lang "editing " <> buf <> "   " <> tr lang "Enter save · Esc cancel"
      Nothing
        | n == 0 -> tr lang "no match"
        | otherwise -> "[" <> T.pack (show n) <> "]"
          <> maybe "" ("  " <>) (spError sp)
    rowsShown = map (padLeftRight 1 . rowFor) [start .. min end (n - 1)]
    visible = visibleRows st
    n = length visible
    sel = spSel p
    editing = case spEdit p of
      Just _  -> True
      Nothing -> False
    (start, end) = windowRange n sel settingsListMax
    rowFor idx = case drop idx visible of
      e : _ -> if idx == sel
        then withAttr (attrName "selection") (fullRow (rowBody e))
        else withAttr (attrName "timestamp") (fullRow (rowBody e))
      [] -> emptyWidget
    -- qwen-style row: label left, fill, value pinned right; * = overridden
    rowBody e = hBox
      [ withAttr (attrName "title") (str (T.unpack (T.take 30 (seLabel e))))
      , fill ' '
      , str (T.unpack (T.take 30 valueText))
      ]
      where
        valueText | seKey e == "token" = maskSecret (seVal e)
                  | otherwise = seVal e
          <> (if isOverridden e then " *" else "")
    -- qwen-style detail line: full description of the selected row
    descRow = case drop sel visible of
      e : _ | not editing && n > 0 ->
        withAttr (attrName "timestamp") $ str (T.unpack (T.take 70 (seHint e)))
      _ -> emptyWidget
    -- bottom help line
    statusRow = padLeftRight 1 $ withAttr (attrName "status") $ str (T.unpack helpText)
    helpText
      | editing = tr lang "Enter save · Esc cancel"
      | otherwise = tr lang "↑/↓ move · Enter edit · Esc close"

-- | Clamp a selection into @[0, n-1]@.
clampSel :: Int -> Int -> Int
clampSel n sel
  | n <= 0 = 0
  | otherwise = max 0 (min sel (n - 1))

-- | Two-column rendering of the Status rows (label column padded).
renderStatusRows :: Lang -> [StatusRow] -> Widget ResourceName
renderStatusRows lang rows =
  vLimit 20 $ vBox [ row r | r <- rows ]
  where
    w = 1 + maximum (map (T.length . tr lang . srLabel) rows)
    padTo x = x <> T.replicate (w - T.length x) " "
    row r = hBox
      [ withAttr (attrName "timestamp") (str (T.unpack (padTo (tr lang (srLabel r)))))
      , str (T.unpack (srValue r))
      ]

-- | Counters for the Stats tab, shaped by UI.StatsView.
computeStatsBlocks :: AppState -> [StatsBlock]
computeStatsBlocks st =
  buildStatsBlocks sid total (u, a, tl, sy) (appLastUsage st) chars
  where
    roles = map msgRole (appMessages st)
    total = length roles
    u  = length (filter (== "user") roles)
    a  = length (filter (== "assistant") roles)
    tl = length (filter (== "tool") roles)
    sy = total - u - a - tl
    chars = sum (map (T.length . msgContent) (appMessages st))
    sid = maybe "—" T.pack (appSessionId st)

-- | Render the three stats sections (title + two-column rows each).
renderStatsBlocks :: Lang -> [StatsBlock] -> Widget ResourceName
renderStatsBlocks lang blocks = vBox (concatMap one blocks)
  where
    one b = [ padLeftRight 1 $ withAttr (attrName "title") $ str (T.unpack (tr lang (sbTitleKey b)))
            , renderStatusRows lang [ StatusRow k v | (k, v) <- sbRows b ]
            , str " "
            ]

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

-- | Current git branch name (from the working tree) or "—".
gitBranchText :: IO Text
gitBranchText = do
  mhead <- readMaybeFile ".git/HEAD"
  case mhead of
    Nothing -> return "—"
    Just hd | "ref: " `T.isPrefixOf` hd -> do
      let refPath = ".git/" <> T.unpack (T.strip (T.drop 5 hd))
      mref <- readMaybeFile refPath
      return (maybe "—" T.strip mref)
    Just hd -> return (T.strip hd)
  where
    readMaybeFile fp = do
      r <- try (TIO.readFile fp) :: IO (Either IOException Text)
      return $ case r of
        Left _  -> Nothing
        Right t -> Just t

-- | Rows shown at once in the settings list (all 11 keys fit on tall screens).
settingsListMax :: Int
settingsListMax = 20
