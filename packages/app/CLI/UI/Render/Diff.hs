{-# LANGUAGE OverloadedStrings #-}

-- | Unified-diff rendering support for the TUI (M3/M3.5, MiMo parity).
--
-- Tool outputs that are diffs (edit/apply-patch style tools) get added/
-- removed colouring instead of the dim output look.  This module is the
-- pure half: classification, hunk-aware line numbering and the width
-- policy.  The widget layer maps classes to attributes.
--
-- Display rule (M3.5-8): the view stays unified at every width.  Narrower
-- than 120 columns the diff is inlined (sigil only); from 120 columns up a
-- 4+4 gutter with the old/new line numbers is added.  MiMo switches to a
-- side-by-side renderer there, but the TUI shows a tail preview of tool
-- output, where pairing hunks buys nothing.
module UI.Render.Diff
  ( -- * Classification
    DiffClass(..)
  , diffClass
    -- * Line model
  , DiffLine(..)
  , parseDiffLines
    -- * Hunk-aware numbering
  , DiffRow(..)
  , numberDiff
  , hunkStart
    -- * Width policy and rendering
  , DiffLayout(..)
  , diffLayout
  , renderDiffRow
  , looksLikeDiff
  ) where

import Control.Monad (guard)
import Data.Char (isDigit)
import Data.Text (Text)
import qualified Data.Text as T
import Text.Read (readMaybe)

-- | Colour class of one source line (C-prefixed: the line model below
-- uses the bare names).
data DiffClass
  = CAdd   -- ^ + line
  | CDel   -- ^ - line
  | CHunk  -- ^ @@ header
  | CMeta  -- ^ ---/+++/diff --git/index
  | CPlain -- ^ everything else
  deriving (Show, Eq)

-- | Classify one line of tool output.  A hunk header is a real unified
-- hunk (@@ -n,m +n,m @@); @+++/---@ file headers win over @+/@- bodies.
diffClass :: Text -> DiffClass
diffClass l
  | "@@ -" `T.isPrefixOf` l = CHunk
  | "+++" `T.isPrefixOf` l = CMeta
  | "---" `T.isPrefixOf` l = CMeta
  | "+" `T.isPrefixOf` l  = CAdd
  | "-" `T.isPrefixOf` l  = CDel
  | "diff " `T.isPrefixOf` l = CMeta
  | "index " `T.isPrefixOf` l = CMeta
  | otherwise = CPlain

-- | One classified source line.
data DiffLine
  = DiffAdd Text
  | DiffDel Text
  | DiffHunk Text
  | DiffMeta Text
  | DiffPlain Text
  deriving (Show, Eq)

-- | Classify a block of tool output line by line.
parseDiffLines :: [Text] -> [DiffLine]
parseDiffLines = map classify
  where
    classify l = case diffClass l of
      CAdd   -> DiffAdd l
      CDel   -> DiffDel l
      CHunk  -> DiffHunk l
      CMeta  -> DiffMeta l
      CPlain -> DiffPlain l

-- | One diff line with the line numbers the hunk header assigns to it.
data DiffRow = DiffRow
  { drClass :: DiffClass
  , drOld   :: Maybe Int
  , drNew   :: Maybe Int
  , drText  :: Text
  } deriving (Show, Eq)

-- | Parse the start line of a unified hunk header (@\@\@ -10,2 +20,3 \@\@@).
-- Counts are optional.  Anything else is not a hunk start.
hunkStart :: Text -> Maybe (Int, Int)
hunkStart line = do
  rest <- T.stripPrefix "@@ -" line
  let (oldPart, plusPart) = T.breakOn " +" rest
  guard (" +" `T.isPrefixOf` plusPart)
  let newPart = T.drop 2 plusPart
  oldNo <- leadingInt oldPart
  newNo <- leadingInt newPart
  pure (oldNo, newNo)
  where
    leadingInt = readMaybe . T.unpack . T.takeWhile isDigit

-- | Number a diff block from its hunk headers.  Context lines advance both
-- counters, a removed line only the old one, an added line only the new
-- one.  Lines outside a hunk (file headers, blank separators) stay
-- unnumbered.
numberDiff :: [Text] -> [DiffRow]
numberDiff = go Nothing Nothing
  where
    go _ _ [] = []
    go oldNo newNo (l : ls) = case hunkStart l of
      Just (o, n) -> DiffRow CHunk Nothing Nothing l : go (Just o) (Just n) ls
      Nothing -> case diffClass l of
        CAdd   -> DiffRow CAdd Nothing newNo l : go oldNo (fmap (+ 1) newNo) ls
        CDel   -> DiffRow CDel oldNo Nothing l : go (fmap (+ 1) oldNo) newNo ls
        CHunk  -> DiffRow CHunk Nothing Nothing l : go oldNo newNo ls
        CMeta  -> DiffRow CMeta Nothing Nothing l : go oldNo newNo ls
        CPlain -> case (oldNo, newNo) of
          (Just o, Just n) ->
            DiffRow CPlain (Just o) (Just n) l : go (Just (o + 1)) (Just (n + 1)) ls
          _ -> DiffRow CPlain Nothing Nothing l : go oldNo newNo ls

-- | How wide the terminal is decides how much gutter the diff gets.
data DiffLayout = DiffInline | DiffNumbered
  deriving (Show, Eq)

-- | Narrow terminals get the inline form; wide ones get line numbers.
diffLayout :: Int -> DiffLayout
diffLayout width
  | width >= 120 = DiffNumbered
  | otherwise    = DiffInline

-- | Render one row for the given layout.  The text itself is not modified
-- (the widget layer may truncate it first).
renderDiffRow :: DiffLayout -> DiffRow -> Text
renderDiffRow DiffInline r = drText r
renderDiffRow DiffNumbered r =
  gutter (drOld r) <> " " <> gutter (drNew r) <> " │ " <> drText r
  where
    gutter = maybe "    " (\n -> T.justifyRight 4 ' ' (T.pack (show n)))

-- | Whether a block is a diff at all.  A hunk header is the reliable
-- signal; a leading @-@ alone could just be a bullet list.
looksLikeDiff :: [Text] -> Bool
looksLikeDiff = any ((== CHunk) . diffClass)
