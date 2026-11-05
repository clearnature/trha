{-# LANGUAGE OverloadedStrings #-}

-- | Esc 的判定：优先级、双击窗口、以及各标志位的连线。
--
-- 实现已上移到 brick 的 @Brick.Escape@（submodule），这里只做重导出，保持
-- trha 内部的 import 路径不变。类型 'EscFlags' / 'EscOutcome' 同样来自 brick。
module UI.Dialog.Escape
  ( resolveEscape, escPress, escWiring
  ) where

import Brick.Escape (escPress, escWiring, resolveEscape)
