{-# LANGUAGE OverloadedStrings #-}

-- | Pure dialog-stack state machine for the TUI (M2, MiMo parity).
--
-- A dialog is a modal overlay pushed on a stack; the top dialog owns key
-- handling until it is popped.  Escape resolution follows MiMo's
-- hierarchy (selection → stack → shell → autocomplete → approval; a
-- running session is only interrupted by a double escape within 5s).
-- Rendering is a concern of @UI.Brick@; this module is the unit-tested
-- core.
module UI.Dialog
  ( -- * Dialog stack
    Dialog(..)
  , SandboxSettings(..)
  , defaultSandboxSettings
  , sandboxApply
  , DialogStack
  , emptyStack
  , stackPush
  , stackPop
  , stackTop
  , stackNull
    -- * Selection
  , dialogMoveSel
  , dialogCount
  , dialogTitle
  , dialogSelected
  , dialogEditable
  , dialogQuery
    -- * Approval options
  , ApprovalOption(..)
  , approvalOptions
  , isDestructiveShell
    -- * Command-dialog editing
  , dialogSkillsAppend
  , dialogSkillsDelete
  , dialogSkillsQuery
  , dialogSkillsItems
  , dialogCommandsAppend
  , dialogCommandsDelete
  , dialogCommandsQuery
  , dialogCommandsSelected
  , dialogCommandsItems
  , dialogCommandsInitialSel
  , dialogModelsAppend
  , dialogModelsDelete
  , dialogModelsQuery
  , dialogModelsItems
  , filterModels
  , filterSessions
  , dialogSessionsAppend
  , dialogSessionsDelete
  , dialogSessionsQuery
  , dialogSessionsItems
    -- * Escape hierarchy
  , EscFlags(..)
  , EscOutcome(..)
  , resolveEscape
  , escPress
  , escWiring
  ) where

import UI.I18n (Lang, tr)

import Core.Types (AgentEntry(..), ModelInfo(..), ProviderInfo(..))
import Core.SessionSummary (SessionSummary(..))
import UI.Skills (Skill(..))
import UI.ProviderPresets (Preset(..))
import UI.Theme (Theme(..))
import UI.Render.Picker
    ( PickerItem(..), filterItems, firstSelectable, moveSelection
    , moveSelectionSkipping, queryAppend, queryDelete )
import Data.Text (Text)
import qualified Data.Text as T

import UI.Dialog.Selection
import UI.Dialog.Stack
import UI.Dialog.Types

dialogModelsAppend :: Char -> Dialog -> Dialog
dialogModelsAppend c (DialogModels ms q _) = DialogModels ms (queryAppend q c) 0

dialogModelsDelete :: Dialog -> Dialog
dialogModelsDelete (DialogModels ms q _) = DialogModels ms (queryDelete q) 0

dialogModelsQuery :: Dialog -> Text
dialogModelsQuery (DialogModels _ q _) = q

-- | 过滤后的模型列表（选中索引指向它）。
dialogModelsItems :: Dialog -> [ModelInfo]
dialogModelsItems (DialogModels ms q _) = filterModels q ms

dialogSessionsAppend :: Char -> Dialog -> Dialog
dialogSessionsAppend c (DialogSessions ss q _) = DialogSessions ss (queryAppend q c) 0

dialogSessionsDelete :: Dialog -> Dialog
dialogSessionsDelete (DialogSessions ss q _) = DialogSessions ss (queryDelete q) 0

dialogSessionsQuery :: Dialog -> Text
dialogSessionsQuery (DialogSessions _ q _) = q

dialogSessionsItems :: Dialog -> [SessionSummary]
dialogSessionsItems (DialogSessions ss q _) = filterSessions q ss

dialogSkillsAppend :: Char -> Dialog -> Dialog
dialogSkillsAppend c (DialogSkills ss q _) = DialogSkills ss (queryAppend q c) 0

dialogSkillsDelete :: Dialog -> Dialog
dialogSkillsDelete (DialogSkills ss q _) = DialogSkills ss (queryDelete q) 0

dialogSkillsQuery :: Dialog -> Text
dialogSkillsQuery (DialogSkills _ q _) = q

dialogSkillsItems :: Dialog -> [Skill]
dialogSkillsItems (DialogSkills ss q _) = filterSkills q ss

dialogCommandsAppend :: Char -> Dialog -> Dialog
dialogCommandsAppend c (DialogCommands all0 q _) =
  let q' = queryAppend q c
  in DialogCommands all0 q' 0

-- | Backspace one query character; the seed @/@ is never eaten (a
-- one-character query is left untouched, so the menu can't empty out).
dialogCommandsDelete :: Dialog -> Dialog
dialogCommandsDelete (DialogCommands all0 q _)
  | T.length q <= 1 = DialogCommands all0 q 0
  | otherwise       = DialogCommands all0 (queryDelete q) 0

dialogCommandsQuery :: Dialog -> Text
dialogCommandsQuery (DialogCommands _ q _) = q

dialogCommandsSelected :: Dialog -> Int
dialogCommandsSelected (DialogCommands _ _ s) = s

-- | The filtered items of the command dialog.
dialogCommandsItems :: Dialog -> [PickerItem]
dialogCommandsItems (DialogCommands all0 q _) = filterItems q all0

-- | 打开命令面板时该停在哪一项：过滤后列表的第一个可选条目。
--
-- 必须基于过滤后的列表计算。'dialogCommandsItems' 每次都用 query 重新过滤，
-- 若按全量列表算索引，过滤到只剩一项时它会越界，回车落到空分支，
-- 表现为「输入 /about 回车毫无反应」。
dialogCommandsInitialSel :: [PickerItem] -> Text -> Int
dialogCommandsInitialSel all0 q = firstSelectable (filterItems q all0)

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
