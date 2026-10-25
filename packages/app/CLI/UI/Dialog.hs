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
  , DialogStack
  , emptyStack
  , stackPush
  , stackPop
  , stackTop
  , stackNull
    -- * Selection
  , dialogMoveSel
  , dialogCount
    -- * Command-dialog editing
  , dialogCommandsAppend
  , dialogCommandsDelete
  , dialogCommandsQuery
  , dialogCommandsSelected
  , dialogCommandsItems
    -- * Escape hierarchy
  , EscFlags(..)
  , EscOutcome(..)
  , resolveEscape
  , escPress
  ) where

import Core.Types (ModelInfo(..))
import Core.SessionSummary (SessionSummary(..))
import UI.Render.Picker (PickerItem(..), filterItems, moveSelection, queryAppend, queryDelete)
import Data.Text (Text)
import qualified Data.Text as T

-- | One modal overlay.  Selection dialogs carry their filtered list plus
-- the selected index; the command dialog carries the full registry (so
-- query edits can re-filter) plus the query and the selection.
data Dialog
  = DialogModels [ModelInfo] Int            -- ^ /models: filtered, selected
  | DialogSessions [SessionSummary] Int     -- ^ /sessions: filtered, selected
  | DialogCommands [PickerItem] Text Int    -- ^ full registry, query, selected
  | DialogApproval Text String [Text] Int   -- ^ ask message, tool, args, selected
  | DialogConfirm Text Int                  -- ^ "always" confirmation, selected (0=yes)
  deriving (Show, Eq)

-- | Stack of open dialogs; the head is the topmost (owns keys).
type DialogStack = [Dialog]

emptyStack :: DialogStack
emptyStack = []

-- | Open a dialog on top of the stack.
stackPush :: Dialog -> DialogStack -> DialogStack
stackPush = (:)

-- | Close the top dialog; popping an empty stack is a no-op.
stackPop :: DialogStack -> DialogStack
stackPop (_ : rest) = rest
stackPop []         = []

-- | The topmost dialog, if any.
stackTop :: DialogStack -> Maybe Dialog
stackTop (d : _) = Just d
stackTop []      = Nothing

-- | Whether the stack is empty (no dialog open).
stackNull :: DialogStack -> Bool
stackNull = null

-- | Filtered item count of a dialog.
dialogCount :: Dialog -> Int
dialogCount (DialogModels ms _)      = length ms
dialogCount (DialogSessions ss _)    = length ss
dialogCount (DialogCommands all0 q _) = length (filterItems q all0)
dialogCount (DialogApproval{})       = 3  -- once / always / reject
dialogCount (DialogConfirm _ _)      = 2  -- yes / no

-- | Move the top dialog's selection by @delta@ (clamped; a no-op on
-- empty lists).
dialogMoveSel :: Int -> Dialog -> Dialog
dialogMoveSel delta d = case d of
  DialogModels ms s      -> DialogModels ms (mv (dialogCount d) s)
  DialogSessions ss s    -> DialogSessions ss (mv (dialogCount d) s)
  DialogCommands all0 q s -> DialogCommands all0 q (mv (dialogCount d) s)
  DialogApproval m t a s  -> DialogApproval m t a (mv (dialogCount d) s)
  DialogConfirm m s       -> DialogConfirm m (mv (dialogCount d) s)
  where
    mv n s = moveSelection delta s n

-- | Append a character to the command query, re-filter the registry and
-- reset the selection.
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

-- | Signals the escape key consults, in MiMo's priority order.
data EscFlags = EscFlags
  { efSelection :: Bool -- ^ text selection active (copy it first)
  , efStack     :: Bool -- ^ a dialog is open (pop it)
  , efShell     :: Bool -- ^ shell mode active (exit it)
  , efComplete  :: Bool -- ^ autocomplete popup open (close it)
  } deriving (Show, Eq)

data EscOutcome
  = EscClearSelection
  | EscPopDialog
  | EscExitShell
  | EscCloseComplete
  | EscApprovalDeny -- ^ MiMo's permission page: escape = reject (see below)
  deriving (Show, Eq)

-- | MiMo's escape hierarchy: selection → dialog stack → shell →
-- autocomplete → approval.  Escape on the approval page is a reject
-- (MiMo's permission page binds escapeKey to reject); interrupting a
-- running session needs a double escape within 5 seconds — see
-- 'escPress'.
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
