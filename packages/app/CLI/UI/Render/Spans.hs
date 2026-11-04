{-# LANGUAGE OverloadedStrings #-}

-- | 渲染用的纯函数层：跨度切分、按列宽换行、字形片段。
--
-- 这些函数原先都长在 @UI.Brick@（4400 行）里，但它们**不碰 @EventM@、
-- 不碰状态机**——只做「文本 → 跨度 / 列宽 → 行」这类可判定的变换。
-- 抽出来以后可以单独测试，Rebrick 主模块只剩事件与装配。
--
-- 拆分遵循依赖方向：纯函数 ← 渲染 ← 交互 ← 命令，反向引用一律不允许。
module UI.Render.Spans
  ( SpanTok(..)
  , boolText
  , diffAttrOf
  , fillLines
  , isCompactionMark
  , spanToks
  , spanToksWith
  , splitAtWidth
  , spinnerFrame
  , todoGlyph
  , truncLine
  ) where

import Brick (AttrName, attrName)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Graphics.Vty as V

import Core.Types (TodoStatus(..))
import UI.Render.Diff (DiffClass(..))
import UI.Render.Markdown (MdSpan(..))
import UI.Render.ToolCard (cardWidth)
import qualified UI.TextWidth as TW

-- | 一段带属性的文本片段（渲染 markdown 的最小单位）。
data SpanTok = SpanTok { tokAttr :: String, tokText :: Text }

boolText :: Bool -> Text
boolText True  = "True"
boolText False = "False"

-- | 待办状态的字形（侧栏与 @/todo@ 共用）。
todoGlyph :: TodoStatus -> Text
todoGlyph TodoPending    = "○"
todoGlyph TodoInProgress = "◐"
todoGlyph TodoDone       = "●"

-- | 调度层的压缩标记（govern 写入的一条 user 消息）。
isCompactionMark :: Text -> Bool
isCompactionMark c =
  let s = T.strip c
  in "[context compacted" `T.isPrefixOf` s || "[context folded" `T.isPrefixOf` s

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

-- | 工具卡里的一行文本：超过卡片宽度就按**列宽**截断（中文占 2 列）。
truncLine :: Text -> Text
truncLine t
  | TW.textWidth t <= cardWidth - 4 = t
  | otherwise                       = TW.takeCells (cardWidth - 5) t <> "…"

-- | Attribute for one diff class (plain output keeps the tool attribute).
diffAttrOf :: DiffClass -> AttrName
diffAttrOf c = attrName $ case c of
  CAdd   -> "diffAdd"
  CDel   -> "diffRemove"
  CHunk  -> "diffHunk"
  CMeta  -> "diffMeta"
  CPlain -> "tool"

spinnerFrame :: Int -> Text
spinnerFrame i = frames !! (i `mod` length frames)
  where frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
