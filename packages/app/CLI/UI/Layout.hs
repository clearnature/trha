-- | Sidebar width policy (M4-1).  Pure functions so the dock/overlay
-- decision and the resulting content width are unit-testable without
-- brick; the widget layer only consumes 'SidebarRender'.
--
-- Rule (plan M4-1): from 80 columns up the sidebar docks to the right of
-- the conversation; below that it becomes an overlay the user opens and
-- closes.  The docked width is one third of the terminal, clamped to
-- 24..42 columns (MiMo's sidebar is 42).  An overlay is always at most 42
-- columns and never narrower than 1.
module UI.Layout
  ( -- * Placement
    SidebarPlacement(..)
  , dockedMinWidth
  , sidebarMaxWidth
  , sidebarPlacement
  , sidebarWidth
    -- * Open / closed
  , SidebarState(..)
  , toggleSidebar
  , SidebarRender(..)
  , sidebarRender
    -- * Conversation width
  , messageWidth
  ) where

-- | How the sidebar relates to the conversation at a given width.
data SidebarPlacement
  = SidebarDocked   -- ^ shares the row with the conversation
  | SidebarOverlay  -- ^ floats above the conversation
  deriving (Show, Eq)

-- | From this terminal width up the sidebar docks.
dockedMinWidth :: Int
dockedMinWidth = 80

-- | Upper bound for both docked and overlay widths (MiMo's 42-column bar).
sidebarMaxWidth :: Int
sidebarMaxWidth = 42

-- | Docked from 80 columns up, overlay below.
sidebarPlacement :: Int -> SidebarPlacement
sidebarPlacement width
  | width >= dockedMinWidth = SidebarDocked
  | otherwise               = SidebarOverlay

-- | Sidebar width for a terminal width.
--
-- Docked: one third of the terminal, clamped to 24..42, so the
-- conversation keeps at least half the row at 80 columns.
-- Overlay: at most 42, leaving a two-column margin, and never below 1.
sidebarWidth :: Int -> Int
sidebarWidth width = case sidebarPlacement width of
  SidebarDocked  -> max 24 (min sidebarMaxWidth (width `div` 3))
  SidebarOverlay -> max 1 (min sidebarMaxWidth (width - 2))

-- | Whether the user has the sidebar open.
data SidebarState = SidebarOpen | SidebarClosed
  deriving (Show, Eq)

-- | Toggle the sidebar (wide terminals dock/undock, narrow ones show/hide
-- the overlay).
toggleSidebar :: SidebarState -> SidebarState
toggleSidebar SidebarOpen   = SidebarClosed
toggleSidebar SidebarClosed = SidebarOpen

-- | What the widget layer should draw for the sidebar.
data SidebarRender
  = RenderDocked Int   -- ^ chrome on the right of the row, this many columns
  | RenderOverlay Int  -- ^ floating card, this many columns
  | RenderNone         -- ^ closed
  deriving (Show, Eq)

-- | Resolve the state and terminal width into a concrete render decision.
sidebarRender :: Int -> SidebarState -> SidebarRender
sidebarRender _ SidebarClosed = RenderNone
sidebarRender width SidebarOpen = case sidebarPlacement width of
  SidebarDocked  -> RenderDocked (sidebarWidth width)
  SidebarOverlay -> RenderOverlay (sidebarWidth width)

-- | Width left for the conversation.
--
-- A docked sidebar takes its columns plus a two-column border and one
-- column of gap; an overlay floats, so the conversation keeps the full
-- width underneath it.
messageWidth :: Int -> SidebarState -> Int
messageWidth width SidebarClosed = max 1 width
messageWidth width SidebarOpen = case sidebarPlacement width of
  SidebarDocked  -> max 1 (width - sidebarWidth width - 3)
  SidebarOverlay -> max 1 width
