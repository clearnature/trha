{-# LANGUAGE OverloadedStrings #-}

-- | 会话视图的纯辅助：本地会话列表的文本化。
--
-- 从 @UI.Brick@ 的交互层拆出。这类函数只做「数据 → 文本」，不构造 Widget、
-- 不碰 @EventM@，因此可脱离终端单测。
module UI.Brick.SessionView
  ( localSessionLines
  , blocksToMessages
  , refreshSidebar
  ) where

import Brick.BChan (BChan, writeBChan)
import Control.Monad (forM_)
import Data.List (find)
import Data.Text (Text)
import qualified Data.Text as T
import System.Directory (getCurrentDirectory)

import Bridge.Scheduler
  ( SchedulerBridge, fetchAgents, fetchServiceStatus, fetchSessionInfo )
import Core.ProjectStore (recordProjectSession)
import Core.Replay (ReplayBlock(..))
import Core.SessionSummary (SessionSummary(..))
import Core.Transcript (listLocalSessions)
import Core.Types (SessionId)
import UI.Event (AppEvent(..))
import UI.I18n (Lang, tr)
import UI.Render.ToolCard (ToolCard(..))
import UI.State (ChatMessage(..), mkMsg, toolMsg)

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
