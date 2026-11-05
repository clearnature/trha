{-# LANGUAGE OverloadedStrings #-}

-- | Pure quick-picker logic (Claude Code / Reasonix style searchable list).
-- The interactive brick layer lives in "UI.Brick"; everything here is a
-- pure function so it can be unit-tested.
module UI.Render.Picker
  ( -- * Items
    PickerItem(..)
    -- * Filtering
  , filterItems
  , buildPalette
  , sectionItem
  , isSection
    -- * Selection & viewport
  , moveSelection
  , moveSelectionSkipping
  , firstSelectable
  , windowRange
    -- * Query editing
  , queryAppend
  , queryDelete
    -- * Limits
  , maxVisible
  ) where

import Data.List (findIndex, sortOn)
import Data.Maybe (fromMaybe)
import qualified Brick.Widgets.FilterList as FL
import Data.Text (Text)
import qualified Data.Text as T

-- | One selectable entry.
data PickerItem = PickerItem
  { piId    :: Text -- ^ stable identifier (here: the command itself)
  , piLabel :: Text -- ^ displayed label
  , piDesc  :: Text -- ^ description, also searched
  } deriving (Show, Eq)

-- | Section header item: @#<id>@ in 'piId', the visible label in 'piLabel'.
sectionItem :: Text -> Text -> PickerItem
sectionItem sid label = PickerItem ("#" <> sid) label ""

-- | True for the non-selectable section headers.
isSection :: PickerItem -> Bool
isSection it = "#" `T.isPrefixOf` piId it

-- | Slash-palette layout: the 3 most recently used skills and 3 most
-- recently used commands first, then each functional command group with its
-- heading (@[(section-id, heading, items)]@), then every skill.
buildPalette
  :: [PickerItem]                     -- ^ recent skills
  -> [PickerItem]                     -- ^ recent commands
  -> [(Text, Text, [PickerItem])]     -- ^ grouped commands: (id, heading, items)
  -> [PickerItem]                     -- ^ all skills
  -> [PickerItem]
buildPalette recentSkills recentCmds groups allSkills =
  [sectionItem "recent" "recent"]
    ++ recentSkills
    ++ recentCmds
    ++ concat [ sectionItem key heading : items
              | (key, heading, items) <- groups, not (null items) ]
    ++ [sectionItem "skills" "skills"]
    ++ sortOn (T.toLower . piLabel) allSkills

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
filterItems = FL.filterBy (\i -> [piId i, piLabel i <> " " <> piDesc i])
moveSelection :: Int -> Int -> Int -> Int
moveSelection = FL.clampSelection
firstSelectable :: [PickerItem] -> Int
firstSelectable = FL.firstEnabled (not . isSection)
moveSelectionSkipping :: Int -> Int -> [PickerItem] -> Int
moveSelectionSkipping delta sel = FL.moveSkipping (not . isSection) delta sel
windowRange :: Int -> Int -> Int -> (Int, Int)
windowRange = FL.windowRange
queryAppend :: Text -> Char -> Text
queryAppend = FL.queryAppend
queryDelete :: Text -> Text
queryDelete = FL.queryDelete
