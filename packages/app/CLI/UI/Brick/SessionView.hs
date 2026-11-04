{-# LANGUAGE OverloadedStrings #-}

-- | 会话视图的纯辅助：本地会话列表的文本化。
--
-- 从 @UI.Brick@ 的交互层拆出。这类函数只做「数据 → 文本」，不构造 Widget、
-- 不碰 @EventM@，因此可脱离终端单测。
module UI.Brick.SessionView
  ( localSessionLines
  ) where

import Data.Text (Text)
import qualified Data.Text as T

import Core.SessionSummary (SessionSummary(..))
import UI.I18n (Lang, tr)

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
