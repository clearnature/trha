{-# LANGUAGE OverloadedStrings #-}

-- | 生命周期类斜杠命令：@/quit@、@/exit@。
--
-- 从 "UI.Brick.Slash" 拆出（认领式分派）。
module UI.Brick.Slash.Lifecycle
  ( handleLifecycleSlash
  ) where

import Brick (EventM, halt)

import UI.Brick.Slash.Ctx (CmdCtx(..))
import UI.State (AppState, ResourceName)

handleLifecycleSlash :: CmdCtx -> Maybe (EventM ResourceName AppState ())
handleLifecycleSlash cx = case cxCmd cx of
  "/quit" -> Just halt
  "/exit" -> Just halt
  _       -> Nothing
