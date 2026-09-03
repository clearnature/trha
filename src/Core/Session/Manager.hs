module Core.Session.Manager
  ( createSession
  , appendEvent
  , getEvents
  ) where

import Core.Session.Types
import Data.IORef
import qualified Data.Map as Map

-- | Create a new session with a given ID
createSession :: SessionId -> IO Session
createSession sid = do
  logRef <- newIORef []
  projRef <- newIORef Map.empty
  return $ Session sid logRef projRef

-- | Append an event to the session log
appendEvent :: Session -> SessionEvent -> IO ()
appendEvent session event = do
  modifyIORef (eventLog session) (++ [event])

-- | Get all events from the session
getEvents :: Session -> IO [SessionEvent]
getEvents session = readIORef (eventLog session)