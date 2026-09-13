{-# LANGUAGE OverloadedStrings #-}

module Infrastructure.CPU.Thread
  ( -- * Thread Management
    ThreadPool(..)
  , createThreadPool
  , destroyThreadPool
  , submitTask
  , waitForAll
  ) where

import Infrastructure.CPU.Types
import Data.Text (Text)
import Control.Concurrent
import Control.Concurrent.STM
import Control.Exception (SomeException, try)

-- | Thread pool
data ThreadPool = ThreadPool
  { poolThreads :: [ThreadId]
  , poolTaskQueue :: TVar [IO ()]
  , poolActive :: TVar Bool
  }

-- | Create a new thread pool
createThreadPool :: Int -> IO (Either CPUError ThreadPool)
createThreadPool numThreads = do
  if numThreads <= 0
    then return $ Left $ ThreadError "Thread count must be positive"
    else do
      taskQueue <- newTVarIO []
      active <- newTVarIO True
      
      threads <- mapM (\_ -> forkIO $ workerThread taskQueue active) [1..numThreads]
      
      return $ Right $ ThreadPool threads taskQueue active

-- | Worker thread
workerThread :: TVar [IO ()] -> TVar Bool -> IO ()
workerThread taskQueue active = do
  isActive <- readTVarIO active
  if isActive
    then do
      task <- atomically $ do
        tasks <- readTVar taskQueue
        case tasks of
          [] -> retry
          (t:ts) -> do
            writeTVar taskQueue ts
            return t
      
      result <- try task :: IO (Either SomeException ())
      case result of
        Left ex -> putStrLn $ "Task failed: " ++ show ex
        Right () -> return ()
      
      workerThread taskQueue active
    else return ()

-- | Destroy the thread pool
destroyThreadPool :: ThreadPool -> IO ()
destroyThreadPool pool = do
  atomically $ writeTVar (poolActive pool) False
  mapM_ killThread (poolThreads pool)

-- | Submit a task to the thread pool
submitTask :: ThreadPool -> IO () -> IO ()
submitTask pool task = do
  atomically $ modifyTVar (poolTaskQueue pool) (++ [task])

-- | Wait for all tasks to complete
waitForAll :: ThreadPool -> IO ()
waitForAll pool = do
  atomically $ do
    tasks <- readTVar (poolTaskQueue pool)
    if null tasks
      then return ()
      else retry