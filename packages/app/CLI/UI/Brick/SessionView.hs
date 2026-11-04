{-# LANGUAGE OverloadedStrings #-}

-- | 会话视图的纯辅助：本地会话列表的文本化。
--
-- 从 @UI.Brick@ 的交互层拆出。这类函数只做「数据 → 文本」，不构造 Widget、
-- 不碰 @EventM@，因此可脱离终端单测。
module UI.Brick.SessionView
  ( localSessionLines
  , blocksToMessages
  ) where

import Data.Text (Text)
import qualified Data.Text as T

import Core.Replay (ReplayBlock(..))
import Core.SessionSummary (SessionSummary(..))
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
