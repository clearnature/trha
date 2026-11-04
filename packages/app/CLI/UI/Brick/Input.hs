{-# LANGUAGE OverloadedStrings #-}

-- | 输入框的纯判定与取值。
--
-- 从 @UI.Brick@（交互层）拆出的最底层一组：提示是否为空、编辑器取值、光标
-- 偏移、确认文案。它们只读 'AppState' 的输入字段，不产生副作用、不构造
-- Widget，其余 @handle*@ 都建立在这组之上。
module UI.Brick.Input
  ( promptIsEmpty
  , editorValue
  , editorCursor
  , alwaysConfirmText
  ) where

import Brick.Widgets.Edit (getCursorPosition, getEditContents)
import Data.Text (Text)
import qualified Data.Text as T

import UI.I18n (Lang, tr)
import UI.State (AppState(..))

-- | 输入框是否为空（只有空白也算空）。
promptIsEmpty :: AppState -> Bool
promptIsEmpty st = T.null (T.strip (T.unlines (getEditContents (appInput st))))

-- | 编辑器当前内容的文本形式（按行以换行连接）。
editorValue :: AppState -> Text
editorValue st = T.intercalate "\n" (getEditContents (appInput st))

-- | 光标在 'editorValue' 单位下的偏移。
--
-- 逐行累加前面各行的长度，再加上行号（换行各占一个字符）与当前列，
-- 这样多行输入里光标位置才算得对。
editorCursor :: AppState -> Int
editorCursor st =
  sum (map T.length (take row ls)) + row + col
  where
    ls = getEditContents (appInput st)
    (row, col) = getCursorPosition (appInput st)

-- | 「总是允许」的确认文案：带参数时附上首个参数（换行压成空格）。
alwaysConfirmText :: Lang -> String -> [Text] -> Text
alwaysConfirmText lang name args =
  tr lang "Always allow " <> T.pack name
    <> case args of (c : _) -> " " <> T.replace "\n" " " c; [] -> ""
    <> tr lang " for future runs?"
