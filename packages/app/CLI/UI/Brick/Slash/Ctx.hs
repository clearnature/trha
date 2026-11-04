{-# LANGUAGE OverloadedStrings #-}

-- | 斜杠命令分支的共享上下文。
--
-- handleSlash 原本在一个 do 块里绑定 t/st/input/cmd/bridge/chan/lang 七个局部量，
-- 28 个分支全部直接引用它们。要把分支拆到独立模块，必须把这七个量显式传递——
-- 这就是 CmdCtx 存在的唯一理由。
module UI.Brick.Slash.Ctx
  ( CmdCtx(..)
  ) where

import Data.Text (Text)

import Brick.BChan (BChan)
import Bridge.Scheduler (SchedulerBridge)
import UI.Event (AppEvent)
import UI.I18n (Lang)
import UI.State (AppState)

data CmdCtx = CmdCtx
  { cxTime   :: Text
  , cxState  :: AppState
  , cxInput  :: Text
  , cxCmd    :: Text
  , cxBridge :: SchedulerBridge
  , cxChan   :: BChan AppEvent
  , cxLang   :: Lang
  }
