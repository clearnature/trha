{-# LANGUAGE OverloadedStrings #-}

-- | In-app text selection for the message area (MiMo's VP mode).
--
-- The selection is expressed in *rendered message coordinates* (row, column),
-- not screen coordinates: the widget layer translates mouse positions after
-- subtracting the viewport scroll offset.  Keeping the model pure makes the
-- cross-row extraction and clamping testable.
module UI.Selection
  ( SelPos(..)
  , Selection(..)
  , normalizeSelection
  , selectionIsEmpty
  , selectionText
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import UI.TextWidth (dropCells, takeCells, textWidth)

-- | One position inside the message lines (0-based row/column).
data SelPos = SelPos
  { spRow :: Int
  , spCol :: Int
  } deriving (Show, Eq, Ord)

-- | Anchor and cursor of a drag selection.
data Selection = Selection
  { selStart :: SelPos
  , selEnd   :: SelPos
  } deriving (Show, Eq)

-- | Order the endpoints (top-left first) independent of drag direction.
normalizeSelection :: Selection -> (SelPos, SelPos)
normalizeSelection (Selection a b)
  | a <= b    = (a, b)
  | otherwise = (b, a)

-- | A click without movement selects nothing.
selectionIsEmpty :: Selection -> Bool
selectionIsEmpty s = let (a, b) = normalizeSelection s in a == b

-- | Text under the selection, joining the covered rows with newlines.
-- Rows or columns outside the supplied lines are clamped away.
selectionText :: [Text] -> Selection -> Text
selectionText lines0 sel
  | null lines0 = ""
  | spRow b < 0 || spRow a >= length lines0 = ""
  | otherwise = T.intercalate "\n"
      [ slice r line
      | r <- [max 0 (spRow a) .. min (length lines0 - 1) (spRow b)]
      , let line = lines0 !! r
      ]
  where
    (a, b) = normalizeSelection sel
    slice r line =
      let lo = if r == spRow a then spCol a else 0
          hi = if r == spRow b then spCol b else textWidth line
      in takeCells (max 0 (hi - max 0 lo)) (dropCells (max 0 lo) line)
