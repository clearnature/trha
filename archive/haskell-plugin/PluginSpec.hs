-- | Contract tests for the plugin kernel (src/Core/Plugin).
--
-- These pin the observable semantics the Cordis-inspired design relies on:
--
--   * RegisterService is last-writer-wins for a name;
--   * SubscribeEvent runs newest-first (the env stores handlers with
--     @insertWith (++)@, so the most recent subscription is at the head);
--   * ProvideEffect cleanups are collected with @cleanup :@, so the Disposer
--     runs them LIFO (stack discipline), which is what resource cleanup needs;
--   * WithContext threads an IO result into the rest of the plugin;
--   * Disposer composition is plain sequencing (@a <> b == a >> b@).
module PluginSpec (pluginSpec) where

import Control.Monad (join)
import Control.Monad.Free (Free (Pure), liftF)
import Data.Dynamic (Dynamic, fromDynamic, toDyn)
import Data.IORef
import qualified Data.Map as Map
import Test.Hspec

import Core.Plugin.Free (Env (..), execPlugin, runPlugin)
import Core.Plugin.Types (Disposer (..), PluginF (..))

newEnv :: IO Env
newEnv = Env <$> newIORef Map.empty <*> newIORef Map.empty <*> newIORef []

runDisposer :: Disposer -> IO ()
runDisposer (Disposer action) = action

asInt :: Maybe Dynamic -> Maybe Int
asInt = (>>= fromDynamic)

pluginSpec :: Spec
pluginSpec = describe "Core.Plugin (contracts)" $ do
  it "lets a later RegisterService win for the same name" $ do
    env <- newEnv
    _ <- runPlugin env $ do
      liftF (RegisterService "svc" (toDyn (1 :: Int)) ())
      liftF (RegisterService "svc" (toDyn (2 :: Int)) ())
    services <- readIORef (envServices env)
    asInt (Map.lookup "svc" services) `shouldBe` Just 2

  it "keeps distinct service names side by side" $ do
    env <- newEnv
    _ <- runPlugin env $ do
      liftF (RegisterService "a" (toDyn (1 :: Int)) ())
      liftF (RegisterService "b" (toDyn (2 :: Int)) ())
    services <- readIORef (envServices env)
    asInt (Map.lookup "a" services) `shouldBe` Just 1
    asInt (Map.lookup "b" services) `shouldBe` Just 2

  it "runs event handlers newest-first" $ do
    env <- newEnv
    seen <- newIORef ([] :: [Int])
    _ <- runPlugin env $ do
      liftF (SubscribeEvent "evt" (\_ -> modifyIORef' seen (++ [1])) ())
      liftF (SubscribeEvent "evt" (\_ -> modifyIORef' seen (++ [2])) ())
    handlers <- readIORef (envEvents env)
    mapM_ ($ toDyn ()) (Map.findWithDefault [] "evt" handlers)
    readIORef seen `shouldReturn` [2, 1]

  it "does not mix handlers of different events" $ do
    env <- newEnv
    seen <- newIORef ([] :: [String])
    _ <- runPlugin env $ do
      liftF (SubscribeEvent "x" (\_ -> modifyIORef' seen (++ ["x"])) ())
      liftF (SubscribeEvent "y" (\_ -> modifyIORef' seen (++ ["y"])) ())
    handlers <- readIORef (envEvents env)
    mapM_ ($ toDyn ()) (Map.findWithDefault [] "x" handlers)
    readIORef seen `shouldReturn` ["x"]

  it "collects ProvideEffect cleanups without running them" $ do
    env <- newEnv
    order <- newIORef ([] :: [Int])
    _ <- runPlugin env $ do
      liftF (ProvideEffect (pure (modifyIORef' order (++ [1]))) ())
      liftF (ProvideEffect (pure (modifyIORef' order (++ [2]))) ())
    readIORef order `shouldReturn` []
    effects <- readIORef (envEffects env)
    length effects `shouldBe` 2

  it "runs ProvideEffect cleanups LIFO (stack discipline)" $ do
    env <- newEnv
    order <- newIORef ([] :: [Int])
    disposer <- runPlugin env $ do
      liftF (ProvideEffect (pure (modifyIORef' order (++ [1]))) ())
      liftF (ProvideEffect (pure (modifyIORef' order (++ [2]))) ())
    runDisposer disposer
    readIORef order `shouldReturn` [2, 1]

  it "threads WithContext results into the continuation" $ do
    env <- newEnv
    seen <- newIORef (0 :: Int)
    _ <- runPlugin env $ do
      n <- join (liftF (WithContext (pure (41 :: Int)) Pure))
      liftF (ProvideEffect (pure (writeIORef seen (n + 1))) ())
    effects <- readIORef (envEffects env)
    sequence_ effects
    readIORef seen `shouldReturn` 42

  it "returns no cleanup actions for a pure plugin" $ do
    env <- newEnv
    actions <- execPlugin env (Pure ())
    length actions `shouldBe` 0

  describe "Disposer" $ do
    it "composes in order (a <> b == a >> b)" $ do
      order <- newIORef ([] :: [Int])
      let a = Disposer (modifyIORef' order (++ [1]))
          b = Disposer (modifyIORef' order (++ [2]))
      runDisposer (a <> b)
      readIORef order `shouldReturn` [1, 2]

    it "mempty is a no-op" $ do
      order <- newIORef ([] :: [Int])
      runDisposer (mempty :: Disposer)
      readIORef order `shouldReturn` []
