{-# LANGUAGE OverloadedStrings #-}

-- | Esc 的判定：优先级、双击窗口、以及各标志位的连线。
--
-- MiMo 的层级：选区 → 对话框栈 → shell → 自动补全 → 审批。
-- 中断运行中的会话需要 5 秒内双击 Esc（见 'escPress'）。
module UI.Dialog.Escape
  ( resolveEscape, escPress, escWiring
  ) where

import UI.Dialog.Types (EscFlags(..), EscOutcome(..))

resolveEscape :: EscFlags -> EscOutcome
resolveEscape f
  | efSelection f = EscClearSelection
  | efStack f     = EscPopDialog
  | efShell f     = EscExitShell
  | efComplete f  = EscCloseComplete
  | otherwise     = EscApprovalDeny

-- | One escape press over the double-press window: @(withinWindow, armed)@
-- → @(fired, armed')@.  A press inside the 5-second window while armed is
-- the interrupting second press; the caller disarms on fire and on any
-- other key.

escPress :: Bool -> Bool -> (Bool, Bool)
escPress withinWindow armed = (fired, armed')
  where
    fired = armed && withinWindow
    -- 任何一次未 fire 的按键都会留下 arm（含窗口外的「重新开始」），
    -- 只有 fire 本身才清空。
    armed' = not (withinWindow && armed)

-- | Wiring-level escape decision.  Only a running turn can be interrupted;
-- an idle press neither fires nor leaves an arm behind.  Returns
-- @(interrupt, keepArmed)@ — the caller maps @keepArmed@ to the new
-- @appEscLast@ (arm with the current time, or clear it).
--
-- This is what keeps three presses from firing twice: 'escPress' disarms on
-- fire, and clearing the timestamp makes the third press a fresh first
-- press.

escWiring :: Bool -> Bool -> Bool -> (Bool, Bool)
escWiring running withinWindow armed
  | not running = (False, False)
  | otherwise   = escPress withinWindow armed
