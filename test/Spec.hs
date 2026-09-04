{-# LANGUAGE OverloadedStrings #-}

import Test.Hspec
import Test.QuickCheck
import Core.Plugin.Types
import Core.Plugin.Free
import Core.Session.Types
import Core.Session.Manager
import Core.Agent.Types
import Core.Agent.StateMachine
import Core.Tools.Types
import Core.Tools.Registry
import Core.Event.Types
import Core.Event.Bus
import Core.Cache.Types
import Core.Cache.Engine
import LLM.Adapter.Types
import LLM.Adapter.Interface
import LLM.Providers.DeepSeek (createDeepSeekProvider)
import Data.IORef
import Data.Dynamic
import qualified Data.Text as T
import qualified Data.Map as Map
import Control.Monad.Free (liftF)

main :: IO ()
main = hspec $ do
  describe "Core.Plugin" $ do
    it "can create and run a plugin" $ do
      env <- Env <$> newIORef Map.empty <*> newIORef Map.empty <*> newIORef []
      let plugin = do
            liftF $ RegisterService "test" (toDyn (42 :: Int)) ()
      disposer <- runPlugin env plugin
      services <- readIORef (envServices env)
      Map.member "test" services `shouldBe` True

  describe "Core.Session" $ do
    it "can create a session and append events" $ do
      session <- createSession "test-session-1"
      appendEvent session (UserMessage "Hello")
      appendEvent session (AssistantMessage "Hi there!")
      events <- getEvents session
      length events `shouldBe` 2

  describe "Core.Agent" $ do
    it "can create an agent and update state" $ do
      let config = AgentConfig "deepseek-chat" 10 30
      agent <- createAgent "agent-1" config
      state <- getState agent
      state `shouldBe` Idle
      updateState agent (Processing "step-1")
      state' <- getState agent
      state' `shouldBe` Processing "step-1"

  describe "Core.Tools" $ do
    it "can register and retrieve tools" $ do
      registry <- createToolRegistry
      let tool = Tool "test-tool" "A test tool" "{}" (\_ -> return (toDyn (42 :: Int)))
      registerTool registry tool
      retrieved <- getTool registry "test-tool"
      case retrieved of
        Just t -> toolName t `shouldBe` "test-tool"
        Nothing -> expectationFailure "Tool not found"

  describe "Core.Event" $ do
    it "can subscribe and publish events" $ do
      bus <- createEventBus
      ref <- newIORef (0 :: Int)
      subscribe bus "test-event" (\dyn -> do
        case fromDynamic dyn of
          Just msg -> writeIORef ref msg
          Nothing -> return ()
        )
      publish bus "test-event" (toDyn (42 :: Int))
      result <- readIORef ref
      result `shouldBe` 42

  describe "Core.Cache" $ do
    it "can cache and retrieve values" $ do
      engine <- createCacheEngine
      cacheInsert engine "key1" (toDyn (42 :: Int))
      result <- cacheLookup engine "key1"
      case result of
        Just dyn -> fromDynamic dyn `shouldBe` Just (42 :: Int)
        Nothing -> expectationFailure "Value not found"

  describe "LLM.Adapter" $ do
    it "can create a DeepSeek adapter" $ do
      adapter <- createDeepSeekProvider "test-key"
      models <- llmModels adapter
      length models `shouldSatisfy` (>= 1)
      modelName (head models) `shouldBe` "deepseek-chat"
