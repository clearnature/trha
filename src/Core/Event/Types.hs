module Core.Event.Types
  ( EventHandler
  , EventName
  ) where

import Data.Dynamic

-- | Event handler type
type EventHandler = Dynamic -> IO ()

-- | Event name identifier
type EventName = String