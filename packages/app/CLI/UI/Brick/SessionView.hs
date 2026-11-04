{-# LANGUAGE OverloadedStrings #-}

-- | 会话视图的纯辅助：本地会话列表的文本化。
--
-- 从 @UI.Brick@ 的交互层拆出。这类函数只做「数据 → 文本」，不构造 Widget、
-- 不碰 @EventM@，因此可脱离终端单测。
module UI.Brick.SessionView
  ( localSessionLines
  , blocksToMessages
  , refreshSidebar
  , resumeSession
  ) where

import Brick (EventM, get, gets, modify)
import Brick.BChan (BChan, writeBChan)
import Control.Concurrent.Async (async)
import Control.Monad (forM_, void, when)
import Control.Monad.IO.Class (liftIO)
import Data.List (find)
import Data.Text (Text)
import qualified Data.Text as T
import System.Directory (getCurrentDirectory)

import Bridge.Scheduler
  ( SchedulerBridge, fetchAgents, fetchServiceStatus, fetchSessionInfo )
import UI.Commands (resumeMessages, resumeSessions)
import Core.ProjectStore (recordProjectSession)
import Core.Replay (ReplayBlock(..), renderReplay)
import Core.SessionSummary (SessionSummary(..), pickLocalSession)
import Core.Transcript (listLocalSessions, loadTranscript)
import Core.Types (SessionId)
import UI.Brick.DialogKeys (scrollBottom)
import UI.Brick.MessageOps (appendMsg, now, setWindowTitle)
import UI.Brick.Toast (showToast)
import UI.Event (AppEvent(..), Route(..))
import UI.I18n (Lang, tr)
import UI.Render.Spans (isCompactionMark)
import UI.Render.ToolCard (ToolCard(..))
import UI.State
  ( AppState(..), ChatMessage(..), ResourceName(..), mkMsg, toolMsg )

-- | 本地会话的编号列表（与 REPL 的输出格式保持一致）。
--
-- 每行形如 @  [1] 标题  (id · 模型 · N turn(s) · tok · 时间)@，缺哪项就省哪项。
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

-- | 把回放块转成消息区的消息。
--
-- 带工具载荷的块还原成 @role = "tool"@ 的独立行（与 'localSessionLines' 同属
-- 「会话 → 视图数据」的纯转换，所以放在一起）。id 按位置重排，保证 append-only
-- 的语义在回放后依然成立。
blocksToMessages :: [ReplayBlock] -> [ChatMessage]
blocksToMessages blocks =
  zipWith (\i m -> m { msgId = i }) [0 ..] (map toMsg blocks)
  where
    toMsg b = case rbTool b of
      Just (name, args) ->
        toolMsg "tool" (ToolCard name args Nothing Nothing [] "") (maybe "" id (rbTime b))
      Nothing           -> mkMsg (rbRole b) (rbContent b) (maybe "" id (rbTime b))

-- | 刷新侧栏所需的三类数据：会话信息、agent 列表、服务状态，外加标题索引。
--
-- 全是 best-effort：调度层没暴露的接口返回空，不影响主流程；
-- 顺手把「项目 → 会话」索引更新一次，侧栏的标题/最近使用才不会过期。
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

-- | 恢复一个本地会话：把 transcript 回放进消息区，并设为当前会话。
--
-- 三处容易踩的语义，代码里都保留了注释：
-- 1. @--all@ 是逃生口：早期 transcript 没记 cwd，按项目列表看不见但仍可恢复
-- 2. 候选 = 本地 transcript ∪ 调度层会话（后者没本地文件但历史可拉回）
-- 3. 压缩标记只存在于调度层，回放时单独显示，否则历史看起来「凭空变短」
resumeSession :: Text -> EventM ResourceName AppState ()
resumeSession selText = do
  lang <- gets appLang
  t <- liftIO now
  cwd <- liftIO getCurrentDirectory
  let wantAll = T.strip selText == "--all"
  bridge0 <- gets appBridge
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
