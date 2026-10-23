-- | Contract tests for the kernel modules the agent loop depends on:
-- tool registry, event bus, cache, FSM and mode table.
--
-- These pin observable behaviour rather than implementation details, and they
-- exist because each module previously had exactly one smoke test.
{-# LANGUAGE OverloadedStrings #-}

module CoreContractSpec (coreContractSpec) where

import Control.Monad (forM_)
import Data.Dynamic (fromDynamic, toDyn)
import Data.IORef
import qualified Data.Text as T
import Test.Hspec

import qualified Core.Agent.Modes as M
import Core.Agent.StateMachine
import Core.Agent.Types
import Core.Cache.Engine
import Core.Cache.Types
import Core.Event.Bus
import Core.Tools.Registry
import Core.Tools.Types

mkTool :: ToolName -> T.Text -> Tool
mkTool name desc = Tool name desc "{}" (\_ -> pure (toDyn ()))

allModes :: [M.AgentMode]
allModes = [minBound .. maxBound]

coreContractSpec :: Spec
coreContractSpec = do
  describe "Core.Tools.Registry (contracts)" $ do
    it "returns Nothing after unregistering" $ do
      reg <- createToolRegistry
      registerTool reg (mkTool "a" "first")
      unregisterTool reg "a"
      found <- fmap (fmap toolName) (getTool reg "a")
      found `shouldBe` Nothing

    it "replaces a tool registered under the same name" $ do
      reg <- createToolRegistry
      registerTool reg (mkTool "a" "first")
      registerTool reg (mkTool "a" "second")
      t <- getTool reg "a"
      fmap toolDescription t `shouldBe` Just "second"

    it "lists every registered tool" $ do
      reg <- createToolRegistry
      registerTool reg (mkTool "a" "first")
      registerTool reg (mkTool "b" "second")
      names <- map toolName <$> listTools reg
      names `shouldMatchList` ["a", "b"]

  describe "Core.Event.Bus (contracts)" $ do
    it "runs handlers newest-first" $ do
      bus <- createEventBus
      seen <- newIORef ([] :: [Int])
      subscribe bus "e" (\_ -> modifyIORef' seen (++ [1]))
      subscribe bus "e" (\_ -> modifyIORef' seen (++ [2]))
      publish bus "e" (toDyn ())
      readIORef seen `shouldReturn` [2, 1]

    it "unsubscribe removes every handler for the event" $ do
      bus <- createEventBus
      seen <- newIORef (0 :: Int)
      subscribe bus "e" (\_ -> modifyIORef' seen (+ 1))
      subscribe bus "e" (\_ -> modifyIORef' seen (+ 1))
      unsubscribe bus "e"
      publish bus "e" (toDyn ())
      readIORef seen `shouldReturn` 0

    it "publishing with no subscribers is a no-op" $ do
      bus <- createEventBus
      publish bus "nobody" (toDyn ())

    it "does not deliver across event names" $ do
      bus <- createEventBus
      seen <- newIORef ([] :: [String])
      subscribe bus "x" (\_ -> modifyIORef' seen (++ ["x"]))
      publish bus "y" (toDyn ())
      readIORef seen `shouldReturn` []

  describe "Core.Cache.Engine (contracts)" $ do
    it "counts hits and misses" $ do
      c <- createCacheEngine
      _ <- cacheLookup c "missing"
      cacheInsert c "k" (toDyn (1 :: Int))
      _ <- cacheLookup c "k"
      stats <- cacheStats c
      cacheHits stats `shouldBe` 1
      cacheMisses stats `shouldBe` 1
      cacheSize stats `shouldBe` 1

    it "overwrites a key without growing the cache" $ do
      c <- createCacheEngine
      cacheInsert c "k" (toDyn (1 :: Int))
      cacheInsert c "k" (toDyn (2 :: Int))
      v <- cacheLookup c "k"
      fmap fromDynamic v `shouldBe` Just (Just (2 :: Int))
      stats <- cacheStats c
      cacheSize stats `shouldBe` 1

  describe "Core.Agent.StateMachine (contracts)" $ do
    it "walks the happy path" $ do
      transition Idle (StartCommand "s1") `shouldBe` Processing "step-1"
      transition (Processing "step-1") (ToolCallCommand "c1" "bash")
        `shouldBe` WaitingForTool "call-1"
      transition (WaitingForTool "call-1") (ToolResultCommand "ok")
        `shouldBe` Processing "step-2"
      transition (Processing "step-2") (CompleteCommand (Result "done" 3))
        `shouldBe` Completed (Result "done" 3)

    it "error wins from any state" $
      transition (Processing "x") (ErrorCommand TimeoutError) `shouldBe` Error TimeoutError

    it "unknown transitions stay in the current state" $
      transition Idle (ToolResultCommand "orphan") `shouldBe` Idle

  describe "Core.Agent.Modes (invariants)" $ do
    it "every mode has a non-empty description" $
      forM_ allModes $ \m ->
        T.null (M.modeDescription (M.getModeConfig m)) `shouldBe` False

    it "modeToText/textToMode round-trips" $
      forM_ allModes $ \m ->
        M.textToMode (M.modeToText m) `shouldBe` Just m

    it "toolsForMode only returns enabled tools" $
      forM_ allModes $ \m ->
        forM_ (M.toolsForMode m) $ \t -> M.toolEnabled t `shouldBe` True

    it "hasTool agrees with toolsForMode" $
      forM_ allModes $ \m ->
        M.hasTool m "bash" `shouldBe` any ((== "bash") . M.toolName) (M.toolsForMode m)
