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

import UI.Dialog.Editing
import UI.Dialog.Selection
import UI.Dialog.Stack
import UI.Dialog.Types

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
