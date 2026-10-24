{-# LANGUAGE OverloadedStrings #-}

-- | The kernel's own per-session gate.
--
-- The scheduler queues callers in-process, but the kernel is the shared
-- resource when several hosts talk to it, so it serializes too. The gate is
-- exercised directly (two threads, one session) rather than through HTTP, where
-- the stub adapter is too fast to overlap reliably.
module SessionGateSpec (sessionGateSpec) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar
import Control.Concurrent.STM (newTVarIO)
import Control.Monad (forM_)
import qualified Data.Set as Set
import Test.Hspec

import API.Server (withSessionGate)

-- | Run an action that records concurrency, then sleeps.
tracked :: MVar (Int, Int) -> IO ()
tracked ref = do
  modifyMVar_ ref $ \(cur, peak) -> do
    let next = cur + 1
    pure (next, max peak next)
  threadDelay 30000
  modifyMVar_ ref $ \(cur, peak) -> pure (cur - 1, peak)

sessionGateSpec :: Spec
sessionGateSpec = describe "kernel session gate" $ do
  it "never runs two actions on one session at the same time" $ do
    gates <- newTVarIO Set.empty
    ref <- newMVar (0, 0)
    done <- newEmptyMVar
    forM_ [1 .. 4 :: Int] $ \_ ->
      forkIO $ withSessionGate gates "s1" (tracked ref) >> putMVar done ()
    mapM_ (\_ -> takeMVar done) [1 .. 4 :: Int]
    (_, peak) <- readMVar ref
    peak `shouldBe` 1

  it "lets different sessions run in parallel" $ do
    gates <- newTVarIO Set.empty
    ref <- newMVar (0, 0)
    done <- newEmptyMVar
    forM_ ["a", "b", "c"] $ \sid ->
      forkIO $ withSessionGate gates sid (tracked ref) >> putMVar done ()
    mapM_ (\_ -> takeMVar done) [1 .. 3 :: Int]
    (_, peak) <- readMVar ref
    peak `shouldBe` 3

  it "releases the gate when the action throws" $ do
    gates <- newTVarIO Set.empty
    _ <- (withSessionGate gates "s2" (ioError (userError "boom")) :: IO ())
           `shouldThrow` anyIOException
    -- a second acquisition would block forever if the gate leaked
    withSessionGate gates "s2" (pure ()) :: IO ()
    pure ()
