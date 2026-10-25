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
    -- * Approval options
  , ApprovalOption(..)
  , approvalOptions
  , isDestructiveShell
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
  , escWiring
  ) where

import Core.Types (ModelInfo(..), ProviderInfo(..))
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
  | DialogProviders [ProviderInfo] Int      -- ^ /provider: providers, selected
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
dialogCount (DialogProviders ps _)   = length ps
dialogCount (DialogApproval _ name args _) = length (approvalOptions name args)
dialogCount (DialogConfirm _ _)      = 2  -- yes / no

-- | Options offered by an approval card, in display order.
data ApprovalOption = ApprovalOnce | ApprovalAlways | ApprovalReject
  deriving (Show, Eq)

-- | MiMo parity: destructive shell commands get no "always" option — a
-- permanent allow on @rm -rf@ is not a mistake the UI should make easy.
-- Everything else gets the full three-way choice.
approvalOptions :: String -> [Text] -> [ApprovalOption]
approvalOptions name args
  | isDestructiveShell name args = [ApprovalOnce, ApprovalReject]
  | otherwise = [ApprovalOnce, ApprovalAlways, ApprovalReject]

-- | Whether a shell tool call can delete data, judged from the tool name
-- and its first argument (the command line).  Deliberately conservative:
-- a false positive only costs one extra prompt.
isDestructiveShell :: String -> [Text] -> Bool
isDestructiveShell name args
  | name `notElem` shellTools = False
  | otherwise = case args of
      (cmd : _) -> destructive cmd
      []        -> False
  where
    shellTools = ["bash", "shell", "run_shell"]
    destructive cmd =
      let toks = dropWhile isPrefix (T.words (T.strip cmd))
      in case toks of
           (verb : rest) -> verb' verb `elem` destructiveVerbs
                            || (verb' verb == "git" && isDestructiveGit rest)
           [] -> False
    isPrefix t = t `elem` ["sudo", "doas", "env"] || "=" `T.isInfixOf` t
    verb' = T.toLower . T.takeWhile (/= '/')
    destructiveVerbs =
      [ "rm", "rmdir", "del", "erase", "format", "mkfs"
      , "dd", "shred", "truncate", "mv" ]
    isDestructiveGit (sub : more) = case T.toLower sub of
      "clean" -> True
      "reset" -> "--hard" `elem` more
      _       -> False
    isDestructiveGit [] = False

-- | Move the top dialog's selection by @delta@ (clamped; a no-op on
-- empty lists).
dialogMoveSel :: Int -> Dialog -> Dialog
dialogMoveSel delta d = case d of
  DialogModels ms s      -> DialogModels ms (mv (dialogCount d) s)
  DialogSessions ss s    -> DialogSessions ss (mv (dialogCount d) s)
  DialogCommands all0 q s -> DialogCommands all0 q (mv (dialogCount d) s)
  DialogProviders ps s     -> DialogProviders ps (mv (dialogCount d) s)
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
