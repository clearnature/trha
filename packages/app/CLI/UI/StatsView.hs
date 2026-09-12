{-# LANGUAGE OverloadedStrings #-}

-- | Stats tab content for the /settings panel -- three sections
-- (Session / Summary / Performance) rendered as label/value rows, in the
-- same two-column style as the Status tab.  Pure module: the caller
-- (UI.Brick) computes the counters, this module shapes them into
-- localisable rows.
module UI.StatsView
  ( StatsBlock(..)
  , buildStatsBlocks
  ) where

import Data.Text (Text)
import qualified Data.Text as T

-- | One stats section: English title key (localised via 'UI.I18n.tr')
-- and label/value rows (label keys are English too).
data StatsBlock = StatsBlock
  { sbTitleKey :: Text
  , sbRows     :: [(Text, Text)]
  } deriving (Show, Eq)

-- | Build the three sections from simple counters:
-- total messages, per-role counts, tool cards, last-reply usage,
-- total message characters, session id.
buildStatsBlocks
  :: Text                 -- ^ session id ("—" when none)
  -> Int                  -- ^ total messages
  -> (Int, Int, Int, Int) -- ^ (user, assistant, tool, system)
  -> Maybe Int            -- ^ last reply tokens
  -> Int                  -- ^ total message characters
  -> [StatsBlock]
buildStatsBlocks sid total (u, a, tl, sy) usage chars =
  [ StatsBlock "Session"
      [ ("Session ID", sid)
      , ("Messages", showNum total)
      , ("User", showNum u)
      , ("Assistant", showNum a)
      , ("Tools", showNum tl)
      , ("System", showNum sy)
      ]
  , StatsBlock "Summary"
      [ ("Message chars", showNum chars)
      , ("Last reply tokens", maybe "—" showNum usage)
      ]
  , StatsBlock "Performance"
      [ ("Performance metrics not yet recorded", "—")
      , ("Message bytes", showNum chars)
      ]
  ]
  where
    showNum n = T.pack (show n)
