module Orchestration.Parallel.Types
  ( Task(..)
  , TaskResult(..)
  , ParallelConfig(..)
  ) where

-- | A task to be executed
data Task a = Task
  { taskId   :: String
  , taskFunc :: IO a
  }

-- | Result of a task execution
data TaskResult a = TaskResult
  { resultId    :: String
  , resultValue :: Either String a
  }

-- | Parallel execution configuration
data ParallelConfig = ParallelConfig
  { maxConcurrency :: Int
  , timeout        :: Int
  } deriving (Show, Eq)