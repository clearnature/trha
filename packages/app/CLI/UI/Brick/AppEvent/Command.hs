{-# LANGUAGE OverloadedStrings #-}

-- | 异步兜底命令的两类回填事件（批次二基建，见
-- docs/plans/commands-completion-plan.md 批次二）：
--
--   * 'EvCommandDone' —— Slash.hs 兜底分支在 worker 线程跑完 executeCommand
--     后回填：输出进转录区、可能被 @/new@ 等改写的 session id 写回状态，
--     并清空命令缓存（与同步路径逐字段对齐）。
--   * 'EvShowPick' —— 需要异步取数的选择器（@/rewind@ 读转录、@/restore@
--     读快照、@/workflow@ 拉模板）在取数完成后打开通用编号选择器
--     'DialogPick'；动作随对话框携带（AppEvent 去 Show 后可带函数）。
module UI.Brick.AppEvent.Command
  ( handleCommandEvent
  ) where

import Brick (EventM, modify)
import Control.Monad.IO.Class (liftIO)

import UI.Brick.MessageOps (appendMsg, now)
import UI.Dialog (Dialog(..), stackPush)
import UI.Event
import UI.State

handleCommandEvent :: AppEvent -> Maybe (EventM ResourceName AppState ())
handleCommandEvent (EvCommandDone mout msid) = Just $ do
  t <- liftIO now
  case mout of
    Just msg -> appendMsg (mkMsg "system" msg t)
    Nothing  -> pure ()
  -- 与同步路径一致：写回（可能被 /new 改写的）会话 id 并清空命令缓存。
  modify $ \s -> s { appSessionId = msid
                   , appCacheNow = Nothing
                   , appCacheSum = (0, 0)
                   , appCacheTurns = 0 }
handleCommandEvent (EvShowPick title items act) = Just $
  -- 动作随对话框走（不再经 AppState 槽位）：两个选择器并存也互不覆盖。
  modify $ \s -> s { appDialogs = stackPush (DialogPick title items act 0) (appDialogs s) }
handleCommandEvent _ = Nothing
