{-# LANGUAGE OverloadedStrings #-}

-- | Unified-diff line classification for the TUI (M3, MiMo parity).
--
-- Tool outputs that are diffs (edit/apply-patch style tools) get added/
-- removed colouring instead of the dim output look.  Pure classification
-- only; the widget layer maps classes to attributes.
module UI.Render.Diff
  ( -- * Classification
    DiffClass(..)
  , diffClass
    -- * Line model
  , DiffLine(..)
  , parseDiffLines
  ) where

import Data.Text (Text)
import qualified Data.Text as T

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
