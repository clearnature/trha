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
import UI.Dialog.Escape
import UI.Dialog.Selection
import UI.Dialog.Stack
import UI.Dialog.Types
