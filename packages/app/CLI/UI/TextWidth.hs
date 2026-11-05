{-# LANGUAGE OverloadedStrings #-}

-- | 终端列宽计算（grapheme cluster 粒度）。
--
-- 实现已上移到 brick 的 @Brick.Widgets.TextWidth@（submodule），这里只做
-- 重导出，保持 trha 内部既有的 import 路径与函数名不变。
--
-- 与 brick 里 @Brick.Widgets.Core.textWidth@ 的区别：那个按单个码点走
-- 平台 @wcwidth@，emoji 在本机被算成 1 列；这里按 Unicode East Asian Width
-- 与 grapheme cluster 计算，emoji 恒为 2 列，且截断不会切开 ZWJ 序列。
module UI.TextWidth
  ( charCellWidth
  , isWideChar
  , graphemes
  , clusterWidth
  , textWidth
  , takeCells
  , dropCells
  ) where

import Data.Text (Text)
import Brick.Widgets.TextWidth
  ( charCellWidth
  , clusterWidth
  , dropCells
  , graphemes
  , isWideChar
  , takeCells
  , textCells
  )

-- | 总列宽。名字沿用 trha 的旧名（brick 里叫 'textCells'，避免与
-- @Brick.Widgets.Core@ 的 @TextWidth@ 类方法重名）。
textWidth :: Text -> Int
textWidth = textCells
