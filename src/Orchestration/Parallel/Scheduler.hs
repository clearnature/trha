{-# LANGUAGE OverloadedStrings #-}

module Orchestration.Parallel.Scheduler
  ( parallel
  , pipeline
  , mapReduce
  ) where

import Orchestration.Parallel.Types
import Control.Concurrent.Async (async, wait, mapConcurrently)
import Control.Concurrent.STM

-- | Execute tasks in parallel
parallel :: [IO a] -> IO [a]
parallel tasks = mapConcurrently id tasks

-- | Execute tasks in pipeline
pipeline :: [a -> IO a] -> a -> IO a
pipeline stages initial = do
  foldl (\acc stage -> acc >>= stage) (return initial) stages

-- | Map-reduce pattern
mapReduce :: (a -> IO b) -> ([b] -> c) -> [a] -> IO c
mapReduce mapper reducer items = do
  results <- mapConcurrently mapper items
  return $ reducer results