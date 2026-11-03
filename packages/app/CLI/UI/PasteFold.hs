{-# LANGUAGE OverloadedStrings #-}

-- | 长粘贴折叠的纯逻辑（可单测，不依赖 brick）。
--
-- 一次粘贴几百行会把输入框整个淹掉：Reasonix 的做法是让输入框只留一个
-- 占位符 @[Pasted text #N · X lines]@，提交前再换回原文。折叠判定、占位符
-- 文本、展开替换都在这里，TUI 只负责把结果放进编辑器。
module UI.PasteFold
  ( pasteFoldsAtChars
  , pasteFoldsAtLines
  , isLongPaste
  , pasteLabel
  , expandPastes
  ) where

import Data.Text (Text)
import qualified Data.Text as T

-- | 超过这个字符数就折叠。
pasteFoldsAtChars :: Int
pasteFoldsAtChars = 1000

-- | 或者超过这么多行。
pasteFoldsAtLines :: Int
pasteFoldsAtLines = 5

isLongPaste :: Text -> Bool
isLongPaste t =
  T.length t > pasteFoldsAtChars
    -- 行数 = 换行数 + 1：4 个 \n 就是 5 行。
    || T.count "\n" t + 1 >= pasteFoldsAtLines

-- | 占位符文本。行数用 @\\n@ 数 + 1，因为末尾没有换行的单行也算一行。
pasteLabel :: Int -> Int -> Text
pasteLabel n nlines =
  "[Pasted text #" <> T.pack (show n) <> " · " <> T.pack (show nlines) <> " lines]"

-- | 把 @[(占位符, 原文)]@ 里的占位符换回原文。
expandPastes :: [(Text, Text)] -> Text -> Text
expandPastes pastes t0 = foldl step t0 pastes
  where
    step acc (label, body) = T.replace label body acc
