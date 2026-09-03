{-# LANGUAGE OverloadedStrings #-}

module Core.Session.Types
  ( Session(..)
  , SessionEvent(..)
  , SessionId
  ) where

import Data.IORef
import qualified Data.Map as Map
import Data.Dynamic
import Data.Text (Text)

-- | Unique identifier for a session
type SessionId = String

-- | Events that can occur in a session
data SessionEvent
  = UserMessage Text
  | AssistantMessage Text
  | ToolCall String Dynamic
  | ToolResult String Dynamic
  | SystemEvent String
  deriving (Show)

-- | A session contains an event log and projections
data Session = Session
  { sessionId   :: SessionId
  , eventLog    :: IORef [SessionEvent]
  , projections :: IORef (Map.Map String Dynamic)
  }