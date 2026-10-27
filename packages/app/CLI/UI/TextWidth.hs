{-# LANGUAGE OverloadedStrings #-}

-- | Terminal-cell width of text, shared by the TUI renderer and the
-- selection/copy logic.
--
-- Ported contract (Reasonix uses @rivo/uniseg@, qwen-code @string-width@):
-- measure and truncate by **grapheme cluster**, not code point.  A combining
-- mark occupies no cell, an East-Asian wide character two, and a ZWJ emoji
-- sequence or a regional-indicator flag two — even though it contains several
-- code points.  @Data.Text.length@ counts code points, which is why a Chinese
-- message used to overflow and an emoji could be split in half.
module UI.TextWidth
  ( charCellWidth
  , isWideChar
  , graphemes
  , clusterWidth
  , textWidth
  , takeCells
  , dropCells
  ) where

import Data.Char (GeneralCategory (..), generalCategory, ord)
import Data.Text (Text)
import qualified Data.Text as T

-- | Cells occupied by one character in a terminal.
charCellWidth :: Char -> Int
charCellWidth c
  | cat `elem` [NonSpacingMark, SpacingCombiningMark, EnclosingMark] = 0
  | cat `elem` [Control, Format, Surrogate, NotAssigned] = 0
  | isWideChar c = 2
  | otherwise = 1
  where
    cat = generalCategory c

-- | East-Asian wide/fullwidth blocks plus the emoji ranges terminals render
-- double-width.
isWideChar :: Char -> Bool
isWideChar c =
  let n = ord c
  in  (n >= 0x1100 && n <= 0x115F)   -- Hangul Jamo
   || (n >= 0x2E80 && n <= 0x303E)   -- CJK radicals .. Kangxi
   || (n >= 0x3041 && n <= 0x33FF)   -- kana, CJK symbols
   || (n >= 0x3400 && n <= 0x4DBF)   -- CJK ext A
   || (n >= 0x4E00 && n <= 0x9FFF)   -- CJK unified
   || (n >= 0xA000 && n <= 0xA4CF)   -- Yi
   || (n >= 0xAC00 && n <= 0xD7A3)   -- Hangul syllables
   || (n >= 0xF900 && n <= 0xFAFF)   -- CJK compatibility
   || (n >= 0xFE30 && n <= 0xFE4F)   -- CJK compatibility forms
   || (n >= 0xFF00 && n <= 0xFF60)   -- fullwidth forms
   || (n >= 0xFFE0 && n <= 0xFFE6)   -- fullwidth signs
   || (n >= 0x1F300 && n <= 0x1F64F) -- emoji (pictographs)
   || (n >= 0x1F900 && n <= 0x1F9FF) -- supplemental emoji
   || (n >= 0x20000 && n <= 0x3FFFD) -- CJK ext B+

-- | Split into grapheme clusters: base + combining marks / variation
-- selectors, ZWJ-joined continuations, and regional-indicator flag pairs.
graphemes :: Text -> [Text]
graphemes = go . T.unpack
  where
    go [] = []
    go (c : d : cs)
      | isRegional c && isRegional d = T.pack [c, d] : go cs
    go (c : cs) = let (cluster, rest) = spanCluster [c] cs in T.pack cluster : go rest

    spanCluster acc [] = (reverse acc, [])
    spanCluster acc (c : cs)
      | isCombining c || c == '\xFE0F' || c == '\xFE0E' = spanCluster (c : acc) cs
      | c == '\x200D' = case cs of
          (n : cs') -> spanCluster (n : c : acc) cs'
          []        -> (reverse acc, [])
      | otherwise = (reverse acc, c : cs)

    isCombining c = generalCategory c `elem` [NonSpacingMark, SpacingCombiningMark, EnclosingMark]
    isRegional c = let n = ord c in n >= 0x1F1E6 && n <= 0x1F1FF

-- | Cells one cluster occupies.  A ZWJ sequence renders as one emoji, and a
-- regional-indicator pair as one flag — both are two cells regardless of how
-- many code points they contain.
clusterWidth :: Text -> Int
clusterWidth g
  | T.any (== '\x200D') g = 2
  | T.length g >= 2 && T.all isRegional g = 2
  | otherwise = case T.uncons g of
      Just (c, _) -> charCellWidth c
      Nothing     -> 0
  where
    isRegional c = let n = ord c in n >= 0x1F1E6 && n <= 0x1F1FF

-- | Total terminal cells of a string.
textWidth :: Text -> Int
textWidth = sum . map clusterWidth . graphemes

-- | The longest prefix that fits in @n@ cells (never splits a cluster).
takeCells :: Int -> Text -> Text
takeCells n t
  | n <= 0 = T.empty
  | otherwise = T.concat (go n (graphemes t))
  where
    go _ [] = []
    go left (g : gs)
      | w <= left = g : go (left - w) gs
      | otherwise = []
      where
        w = clusterWidth g

-- | Drop the prefix that fits in @n@ cells (the complement of 'takeCells').
dropCells :: Int -> Text -> Text
dropCells n t
  | n <= 0 = t
  | otherwise = T.concat (go n (graphemes t))
  where
    go _ [] = []
    go left (g : gs)
      | w <= left = go (left - w) gs
      | otherwise = g : gs
      where
        w = clusterWidth g
