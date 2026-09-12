{-# LANGUAGE OverloadedStrings #-}

-- | Pure quick-picker logic (Claude Code / Reasonix style searchable list).
-- The interactive brick layer lives in "UI.Brick"; everything here is a
-- pure function so it can be unit-tested.
module UI.Render.Picker
  ( -- * Items
    PickerItem(..)
    -- * Filtering
  , filterItems
    -- * Selection & viewport
  , moveSelection
  , windowRange
    -- * Query editing
  , queryAppend
  , queryDelete
    -- * Limits
  , maxVisible
  ) where

import Data.Text (Text)
import qualified Data.Text as T

-- | One selectable entry.
data PickerItem = PickerItem
  { piId    :: Text -- ^ stable identifier (here: the command itself)
  , piLabel :: Text -- ^ displayed label
  , piDesc  :: Text -- ^ description, also searched
  } deriving (Show, Eq)

-- | Maximum number of rows shown at once.
maxVisible :: Int
maxVisible = 8

-- | Filter items against the query.  An empty (or blank) query returns
-- everything.  The search is case-insensitive over the id, label and
-- description.
--
-- Note: prefix aliasing is expected -- @\/model@ also matches
-- @\/models@; exact-command dispatch is handled by the caller.
filterItems :: Text -> [PickerItem] -> [PickerItem]
filterItems query items
  | T.null q = items
  | otherwise = filter matches items
  where
    q = T.toLower (T.strip query)
    matches item =
      T.isInfixOf q (T.toLower (piId item))
        || T.isInfixOf q (T.toLower (piLabel item <> " " <> piDesc item))

-- | Move the selection by a delta, clamped to the valid range.
-- Arguments: delta, current selection, total item count
-- (an empty list keeps the selection at 0).
moveSelection :: Int -> Int -> Int -> Int
moveSelection delta selected total
  | total <= 0 = 0
  | otherwise = max 0 (min (selected + delta) (total - 1))

-- | Visible window @(first, last)@ of a scrollable list, keeping the
-- selection roughly centred.  An empty list yields @(0, -1)@.
windowRange :: Int -> Int -> Int -> (Int, Int)
windowRange total selected height
  | total <= 0 = (0, -1)
  | total <= height = (0, total - 1)
  | height <= 0 = (selected, selected - 1)
  | otherwise =
      let start = max 0
            (min (selected - (height - 1) `div` 2) (total - height))
      in (start, start + height - 1)

-- | Append a printable character to the query.
queryAppend :: Text -> Char -> Text
queryAppend q c = T.snoc q c

-- | Delete the last character of the query (one full Unicode character).
queryDelete :: Text -> Text
queryDelete = T.dropEnd 1
