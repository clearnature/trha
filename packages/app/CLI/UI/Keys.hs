{-# LANGUAGE OverloadedStrings #-}

-- | Leader-key table (M4-3).  Pressing the leader (ctrl+x) arms one
-- keystroke; the next key runs an action or cancels.  Pure table so the
-- bindings are unit-testable and documented in one place.
module UI.Keys
  ( LeaderAction(..)
  , leaderResolve
  , leaderHelp
  , CtrlCAction(..)
  , decideCtrlC
  , decideCtrlD
  ) where

import Data.Text (Text)
import Data.Time.Clock (UTCTime, diffUTCTime)

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

-- | What Ctrl+C does, following the terminal convention (Reasonix, Claude
-- Code): interrupt work first, clear input second, and only quit on a second
-- press from an idle empty prompt.
data CtrlCAction
  = CtrlCInterrupt     -- ^ a turn is running
  | CtrlCClearInput    -- ^ the prompt is not empty
  | CtrlCQuit          -- ^ idle, empty, and the arm window has not expired
  | CtrlCArmQuit       -- ^ idle and empty: show the "press again" hint
  deriving (Show, Eq)

-- | Window in which a second Ctrl+C quits.
ctrlCWindowSeconds :: Integer
ctrlCWindowSeconds = 3

decideCtrlC :: Bool -> Bool -> Maybe UTCTime -> UTCTime -> CtrlCAction
decideCtrlC busy hasInput armed now
  | busy = CtrlCInterrupt
  | hasInput = CtrlCClearInput
  | Just t <- armed, diffUTCTime now t <= fromIntegral ctrlCWindowSeconds = CtrlCQuit
  | otherwise = CtrlCArmQuit

-- | Ctrl+D quits only from an idle, empty prompt (the terminal EOF convention).
decideCtrlD :: Bool -> Bool -> Bool
decideCtrlD busy hasInput = not busy && not hasInput
