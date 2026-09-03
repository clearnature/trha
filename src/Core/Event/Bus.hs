module Core.Event.Bus
  ( EventBus(..)
  , createEventBus
  , subscribe
  , unsubscribe
  , publish
  ) where

import Core.Event.Types
import Data.IORef
import qualified Data.Map as Map
import Data.Dynamic

-- | Event bus for pub/sub communication
data EventBus = EventBus
  { subscribers :: IORef (Map.Map EventName [EventHandler])
  }

-- | Create a new event bus
createEventBus :: IO EventBus
createEventBus = do
  subsRef <- newIORef Map.empty
  return $ EventBus subsRef

-- | Subscribe to an event type
subscribe :: EventBus -> EventName -> EventHandler -> IO ()
subscribe bus eventType handler = do
  modifyIORef (subscribers bus) (Map.insertWith (++) eventType [handler])

-- | Unsubscribe from an event type (removes all handlers for that type)
unsubscribe :: EventBus -> EventName -> IO ()
unsubscribe bus eventType = do
  modifyIORef (subscribers bus) (Map.delete eventType)

-- | Publish an event
publish :: EventBus -> EventName -> Dynamic -> IO ()
publish bus eventType payload = do
  subsMap <- readIORef (subscribers bus)
  case Map.lookup eventType subsMap of
    Nothing -> return ()
    Just handlers -> mapM_ (\handler -> handler payload) handlers