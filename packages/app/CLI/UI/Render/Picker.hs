{-# LANGUAGE OverloadedStrings #-}

-- | Pure quick-picker logic (Claude Code / Reasonix style searchable list).
-- The interactive brick layer lives in "UI.Brick"; everything here is a
-- pure function so it can be unit-tested.
module UI.Render.Picker
  ( -- * Items
    PickerItem(..)
    -- * Filtering
  , MatchTier(..)
  , matchTier
  , rankByQuery
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

-- ---------------------------------------------------------------------------
-- 匹配强度分级与排序（批次四，对标 qwen 的 completion 排序：
-- EXACT > PREFIX > 其余 infix 命中，frecency 与名字作次级键）
-- ---------------------------------------------------------------------------

-- | 匹配强度档位：越小越强。
--
-- 查询与候选 id 都先去掉首字符 @/@ 并转小写再比较。
data MatchTier = MExact | MPrefix | MInfix | MFuzzy
  deriving (Show, Eq, Ord)

-- | @sub@ 是否为 @s@ 的子序列（保持顺序、允许跳字）。
isSubseq :: Text -> Text -> Bool
isSubseq sub s = go (T.unpack sub) (T.unpack s)
  where
    go [] _ = True
    go _ [] = False
    go (c : cs) (k : ks)
      | c == k = go cs ks
      | otherwise = go (c : cs) ks

-- | 候选 id 对查询的匹配档位（调用方已用 infix 过滤，命中者至少是 'MInfix'）。
matchTier :: Text -> PickerItem -> Int
matchTier q it
  | key == q  = 0
  | q `T.isPrefixOf` key = 1
  | q `T.isInfixOf` key || q `T.isInfixOf` T.toLower (piDesc it) = 2
  | isSubseq ql key = 3
  | otherwise = 4  -- 无匹配（调用方应滤掉）
  where
    ql = T.toLower q
    key = T.toLower (T.drop 1 (piId it))

-- | 按 匹配档位 → frecency 次数（降序）→ 名字 排序。
--
-- @frec@ 给出命令的使用次数（缺省 0）。空查询全部归 'MInfix' 档，
-- 等效于纯 frecency 排序。
-- @q@ 是调用方已去掉斜杠的查询文本（与 Palette.hs 的 query 约定一致）。
rankByQuery :: Text -> (Text -> Int) -> [PickerItem] -> [PickerItem]
rankByQuery q frec items
  -- 空查询：全部候选按 frecency 降序。
  | T.null ql = sortOn (negate . frec . piId) items
  -- 非空：infix → fuzzy 子序列 全收（tier 决定次序），完全无关联的被滤掉。
  | otherwise = map (\(_, _, _, it) -> it) $
      sortOn (\(t, c, n, _) -> (t, c, n))
        [ (matchTier ql it, negate (frec (piId it)), key it, it)
        | it <- items, matchTier ql it < 4 ]
  where
    ql = T.toLower (T.strip q)
    key it = T.toLower (T.drop 1 (piId it))
