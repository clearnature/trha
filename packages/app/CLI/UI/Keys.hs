{-# LANGUAGE OverloadedStrings #-}

-- | Leader-key table (M4-3).  Pressing the leader (ctrl+x) arms one
-- keystroke; the next key runs an action or cancels.  Pure table so the
-- bindings are unit-testable and documented in one place.
module UI.Keys
  ( LeaderAction(..)
  , leaderResolve
  , leaderHelp
  ) where

import Data.Text (Text)

-- | What a leader keystroke can do.
data LeaderAction
  = LeaderSidebar    -- ^ b: dock/undock (or show/hide) the sidebar
  | LeaderProvider   -- ^ p: provider picker
  | LeaderModels     -- ^ m: model picker
  | LeaderSessions   -- ^ s: session picker
  | LeaderSettings   -- ^ ,: settings panel
  | LeaderHelp       -- ^ ?: help text
  | LeaderInterrupt  -- ^ i: interrupt the running turn
  deriving (Show, Eq)

-- | Resolve the keystroke after the leader; Nothing cancels.
leaderResolve :: Char -> Maybe LeaderAction
leaderResolve c = lookup c table
  where
    table =
      [ ('b', LeaderSidebar)
      , ('p', LeaderProvider)
      , ('m', LeaderModels)
      , ('s', LeaderSessions)
      , (',', LeaderSettings)
      , ('?', LeaderHelp)
      , ('i', LeaderInterrupt)
      ]

-- | Status-bar hint shown while the leader is armed.
leaderHelp :: Text
leaderHelp =
  "Leader: b sidebar · p provider · m models · s sessions · , settings · ? help · i interrupt · esc cancel"
