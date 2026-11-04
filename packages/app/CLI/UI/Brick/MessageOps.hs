{-# LANGUAGE OverloadedStrings #-}

-- | 消息操作的基础件：当前时间戳与消息追加。
--
-- 从 @UI.Brick@ 的交互层拆出。两者都是「别的模块调它、它不调别人」的叶子，
-- 中断审批、对话框激活、命令分派都建立在它们之上。
module UI.Brick.MessageOps
  ( now
  , appendMsg
  ) where

import Brick (EventM, modify)
import Data.Text (Text)
import Data.Time.Clock (getCurrentTime)
import Data.Time.LocalTime (getCurrentTimeZone)

import UI.State (AppState(..), ChatMessage(..), ResourceName(..))
import UI.TimeStamp (clockWithZone)

-- | 当前本地时间的简短显示形式（@HH:MM:SS 时区@）。
now :: IO Text
now = do
  t <- getCurrentTime
  tz <- getCurrentTimeZone
  pure (clockWithZone tz t)

-- | 追加一条消息，并打上递增的位置 id。
--
-- id 只增不减（append-only），所以它同时是「消息在列表中的稳定位置」：
-- 折叠状态、卡片焦点、渲染缓存都以它为键。
appendMsg :: ChatMessage -> EventM ResourceName AppState ()
appendMsg msg = modify $ \st ->
  let i = appNextMsgId st
  in st { appMessages = appMessages st ++ [msg { msgId = i }]
        , appNextMsgId = i + 1 }
