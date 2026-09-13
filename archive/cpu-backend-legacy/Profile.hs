{-# LANGUAGE OverloadedStrings #-}

module Infrastructure.CPU.Profile
  ( -- * Profiling
    ProfilingConfig(..)
  , defaultProfilingConfig
  , startProfiling
  , stopProfiling
  , getProfilingResults
  , ProfilingResult(..)
  ) where

import Data.Text (Text)
import Data.Time (UTCTime, diffUTCTime, getCurrentTime)
import Data.IORef

-- | Profiling configuration
data ProfilingConfig = ProfilingConfig
  { profilingEnabled :: Bool
  , profilingThreads :: Bool
  , profilingSIMD :: Bool
  , profilingDetail :: Bool
  } deriving (Show, Eq)

-- | Default profiling configuration
defaultProfilingConfig :: ProfilingConfig
defaultProfilingConfig = ProfilingConfig
  { profilingEnabled = False
  , profilingThreads = True
  , profilingSIMD = True
  , profilingDetail = False
  }

-- | Profiling result
data ProfilingResult = ProfilingResult
  { resultName :: Text
  , resultThreadTime :: Maybe Double
  , resultSIMDTime :: Maybe Double
  , resultTimestamp :: UTCTime
  } deriving (Show)

-- | Global profiling state
profilingState :: IORef [ProfilingResult]
profilingState = unsafePerformIO $ newIORef []
{-# NOINLINE profilingState #-}

-- | Start profiling
startProfiling :: ProfilingConfig -> IO ()
startProfiling config = do
  if profilingEnabled config
    then do
      writeIORef profilingState []
      putStrLn "Profiling started"
    else return ()

-- | Stop profiling
stopProfiling :: IO ()
stopProfiling = do
  putStrLn "Profiling stopped"

-- | Get profiling results
getProfilingResults :: IO [ProfilingResult]
getProfilingResults = do
  readIORef profilingState

-- | Record a profiling result
recordProfilingResult :: Text -> Maybe Double -> Maybe Double -> IO ()
recordProfilingResult name threadTime simdTime = do
  timestamp <- getCurrentTime
  let result = ProfilingResult name threadTime simdTime timestamp
  modifyIORef profilingState (result :)

-- Helper function for unsafePerformIO
unsafePerformIO :: IO a -> a
unsafePerformIO (IO m) = case m realWorld# of (# _, a #) -> a