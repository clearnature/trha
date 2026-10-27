{-# LANGUAGE OverloadedStrings #-}

-- | The interaction-layer model (IA §6): /which layer owns the keyboard/, and
-- /which layer each slash command must enter/.
--
-- The TUI is not a flat command list: it is a tree of interaction layers
-- (editor → completion → palette → dialog stack → wizard → settings →
-- terminal handover → async turn).  A command "works" only when it enters
-- the right layer /and/ writes its result back to the right state; the second
-- half is a wiring concern, but the first half is data and belongs here.
--
-- Pure module -- no brick, no IO -- so the routing contract can be tested
-- before it is wired (that is the point: D1/D3/D5 in the IA doc were all
-- invisible to tests because the layer decision lived inside 'UI.Brick').
module UI.Interaction
  ( -- * Layers
    Layer(..)
  , allLayers
  , layerLabel
    -- * Keyboard ownership and escape priority
  , keyOwnerOrder
  , escapeOrder
  , resolveEscapeLayer
    -- * Command → layer
  , CommandLayer(..)
  , commandLayerLabel
  , layerTable
  , commandLayerOf
  , commandsInLayer
  , unknownLayerCommands
  ) where

import Data.List (nub)
import Data.Text (Text)
import qualified Data.Text as T

--------------------------------------------------------------------------------
-- Layers
--------------------------------------------------------------------------------

-- | One interaction layer.  Values are ordered by /nesting depth/: a higher
-- constructor may be opened on top of a lower one, never the reverse.
data Layer
  = LayerEditor      -- ^ L0: the composer owns keys; everything floats above it
  | LayerCompletion  -- ^ L1: inline @\@@-completion popup
  | LayerPalette     -- ^ L2: inline slash-command palette (not a modal)
  | LayerLeader      -- ^ L3: @ctrl+x@ leader, one keystroke then disarms
  | LayerDialog      -- ^ L4: modal dialog stack, top owns every key
  | LayerWizard      -- ^ L4.5: provider add/edit steps (nested in L4)
  | LayerSettings    -- ^ L5: full-screen settings takeover
  | LayerTerminal    -- ^ L6: terminal handed to a child process
  | LayerTurn        -- ^ L7: an async turn is running (a mode, not an overlay)
  deriving (Show, Eq, Ord, Enum, Bounded)

allLayers :: [Layer]
allLayers = [minBound .. maxBound]

layerLabel :: Layer -> Text
layerLabel l = case l of
  LayerEditor     -> "editor"
  LayerCompletion -> "completion"
  LayerPalette    -> "palette"
  LayerLeader     -> "leader"
  LayerDialog     -> "dialog"
  LayerWizard     -> "wizard"
  LayerSettings   -> "settings"
  LayerTerminal   -> "terminal"
  LayerTurn       -> "turn"

--------------------------------------------------------------------------------
-- Keyboard ownership and escape priority
--------------------------------------------------------------------------------

-- | Who interprets an ordinary key, highest priority first.
--
-- This mirrors the real router in @UI.Brick@ ('handleEvent'): settings and an
-- open dialog are modal, the leader is transient, and the chat handler owns
-- everything else (it consults completion → palette → editor internally).
keyOwnerOrder :: [Layer]
keyOwnerOrder =
  [ LayerSettings
  , LayerDialog
  , LayerLeader
  , LayerEditor
  ]

-- | Who consumes an Escape press, highest priority first.
--
-- 'UI.Dialog.resolveEscape' only knew four of these (selection / stack / shell
-- / completion), while the router also had to consider settings, the wizard
-- and the palette — two models that disagreed (IA §6.4 D1).  This is the
-- single order both sides should consult.
escapeOrder :: [Layer]
escapeOrder =
  [ LayerSettings   -- full-screen panel: Esc leaves it
  , LayerWizard     -- cancel the six-step provider wizard
  , LayerCompletion -- close the inline popup first
  , LayerPalette    -- then the command palette (input is preserved)
  , LayerLeader     -- an armed leader disarms on Esc
  , LayerDialog     -- pop the modal stack
  , LayerTerminal   -- leave shell mode
  , LayerTurn       -- only a running turn is left; Esc denies / interrupts
  , LayerEditor     -- nothing open: Esc is a no-op at this level
  ]

-- | The layer that handles Escape, given the layers currently active.
--
-- 'LayerEditor' is the fallback: with nothing open, Escape belongs to nobody
-- in particular and the caller decides (double-press interrupt window).
resolveEscapeLayer :: [Layer] -> Layer
resolveEscapeLayer active =
  case filter (`elem` active) escapeOrder of
    (l : _) -> l
    []      -> LayerEditor

--------------------------------------------------------------------------------
-- Command → layer
--------------------------------------------------------------------------------

-- | Which layer a slash command must enter.  The classification is about the
-- /highest/ effect a command can cause: @\/model@ with no argument only prints,
-- but @\/model x@ writes state, so it is 'CmdState'.
data CommandLayer
  = CmdReply     -- ^ L0: produce text and return (no state, no long IO)
  | CmdPicker    -- ^ L4: open a dialog / selector
  | CmdWizard    -- ^ L4.5: enter the provider wizard
  | CmdPanel     -- ^ L5: open the settings panel
  | CmdTerminal  -- ^ L6: hand the terminal to a child process
  | CmdAsync     -- ^ L7: network or long work -- must not block the key thread
  | CmdState     -- ^ L7-lite: write local/shell state, repaint, no turn
  | CmdExit      -- ^ halt the shell
  deriving (Show, Eq, Ord, Enum, Bounded)

commandLayerLabel :: CommandLayer -> Text
commandLayerLabel c = case c of
  CmdReply    -> "reply"
  CmdPicker   -> "picker"
  CmdWizard   -> "wizard"
  CmdPanel    -> "panel"
  CmdTerminal -> "terminal"
  CmdAsync    -> "async"
  CmdState    -> "state"
  CmdExit     -> "exit"

-- | The command → layer table.  Keys are registry command names (including the
-- leading slash); 'UI.Commands.Registry.slashRegistry' is the authority for
-- which names exist, and 'UI.InteractionSpec' asserts the two sets match
-- exactly -- so adding a command without classifying it fails the build's
-- tests instead of silently falling through to a synchronous handler.
layerTable :: [(Text, CommandLayer)]
layerTable =
  [ -- L0 -- text only
    ("/help", CmdReply)
  , ("/status", CmdReply)
  , ("/context", CmdReply)
  , ("/stats", CmdReply)
  , ("/transcript", CmdReply)
  , ("/todo", CmdReply)
  , ("/tree", CmdReply)
  , ("/memory", CmdReply)
  , ("/preset", CmdReply)
  , ("/hooks", CmdReply)
  , ("/diff", CmdReply)
  , ("/currency", CmdReply)
  , ("/attachments", CmdReply)
    -- L4 -- selectors
  , ("/models", CmdPicker)
  , ("/provider", CmdPicker)
  , ("/sessions", CmdPicker)
  , ("/skills", CmdPicker)
  , ("/agents", CmdPicker)
  , ("/theme", CmdPicker)
  , ("/language", CmdPicker)
  , ("/resume", CmdPicker)
  , ("/delete", CmdPicker)
    -- L5 -- settings
  , ("/settings", CmdPanel)
    -- L6 -- terminal handover
  , ("/vim", CmdTerminal)
    -- L7 -- async (network / long work); must never run on the key thread
  , ("/retry", CmdAsync)
  , ("/btw", CmdAsync)
  , ("/recap", CmdAsync)
  , ("/compact", CmdAsync)
  , ("/queue", CmdAsync)
  , ("/steer", CmdAsync)
  , ("/fork", CmdAsync)
  , ("/branch", CmdAsync)
  , ("/loop", CmdAsync)
  , ("/workflow", CmdAsync)
  , ("/plan", CmdAsync)
  , ("/approve", CmdAsync)
  , ("/deny", CmdAsync)
  , ("/skip", CmdAsync)
  , ("/reject", CmdAsync)
  , ("/abandon", CmdAsync)
  , ("/new", CmdAsync)
  , ("/mode", CmdAsync)
  , ("/switch", CmdAsync)
  , ("/rename", CmdAsync)
  , ("/tag", CmdAsync)
  , ("/doctor", CmdAsync)
  , ("/mcp", CmdAsync)
  , ("/lsp", CmdAsync)
  , ("/usage", CmdAsync)
  , ("/session-info", CmdAsync)
  , ("/goal", CmdAsync)
  , ("/graph", CmdAsync)
  , ("/plugins", CmdAsync)
    -- L7-lite -- local state writes
  , ("/model", CmdState)
  , ("/home", CmdState)
  , ("/stash", CmdState)
  , ("/fav", CmdState)
  , ("/export", CmdState)
  , ("/remember", CmdState)
  , ("/clear-attachments", CmdState)
  , ("/paste", CmdState)
  , ("/output-style", CmdState)
  , ("/cls", CmdState)
  , ("/ask-timeout", CmdState)
  , ("/reasoning-language", CmdState)
  , ("/clear", CmdState)
  , ("/copy", CmdState)
  , ("/verbose", CmdState)
    -- exit
  , ("/quit", CmdExit)
  , ("/exit", CmdExit)
  , ("/stop", CmdExit)
  ]

-- | Layer of a registered command; 'Nothing' means the command was added to
-- the registry without being classified (the spec fails on that).
commandLayerOf :: Text -> Maybe CommandLayer
commandLayerOf name = lookup name layerTable

-- | Commands assigned to one layer, in table order.
commandsInLayer :: CommandLayer -> [Text]
commandsInLayer c = [ n | (n, c') <- layerTable, c' == c ]

-- | Registry names missing from the table (empty is the invariant).
unknownLayerCommands :: [Text] -> [Text]
unknownLayerCommands registered = nub [ n | n <- registered, commandLayerOf n == Nothing ]
