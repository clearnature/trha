module Infrastructure.Telemetry.Metrics
  ( Metrics(..)
  , createMetrics
  , increment
  , record
  ) where

import Data.IORef
import qualified Data.Map as Map

-- | Metrics collector
data Metrics = Metrics
  { counters :: IORef (Map.Map String Int)
  , gauges   :: IORef (Map.Map String Double)
  }

-- | Create a new metrics collector
createMetrics :: IO Metrics
createMetrics = do
  countersRef <- newIORef Map.empty
  gaugesRef <- newIORef Map.empty
  return $ Metrics countersRef gaugesRef

-- | Increment a counter
increment :: Metrics -> String -> IO ()
increment metrics name = do
  modifyIORef (counters metrics) (Map.insertWith (+) name 1)

-- | Record a gauge value
record :: Metrics -> String -> Double -> IO ()
record metrics name val = do
  modifyIORef (gauges metrics) (Map.insert name val)