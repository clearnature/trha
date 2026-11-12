{-# LANGUAGE OverloadedStrings #-}

-- | 异步兜底命令的两类回填事件（批次二基建，见
-- docs/plans/commands-completion-plan.md 批次二）：
--
--   * 'EvCommandDone' —— Slash.hs 兜底分支在 worker 线程跑完 executeCommand
--     后回填：输出进转录区、可能被 @/new@ 等改写的 session id 写回状态，
--     并清空命令缓存（与同步路径逐字段对齐）。
--   * 'EvShowPick' —— 需要异步取数的选择器（@/rewind@ 读转录、@/restore@
--     读快照、@/workflow@ 拉模板）在取数完成后打开通用编号选择器
--     'DialogPick'；动作本体由认领分支事先写入 AppState.appPickAction。
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
handleCommandEvent (EvShowPick title items) = Just $
  -- 动作本体已在认领分支写入 AppState.appPickAction，Enter 时由
  -- DialogActivate 读取执行；这里只负责把选择器压栈。
  modify $ \s -> s { appDialogs = stackPush (DialogPick title items 0) (appDialogs s) }
handleCommandEvent _ = Nothing
