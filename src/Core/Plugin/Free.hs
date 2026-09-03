{-# LANGUAGE ExistentialQuantification #-}

module Core.Plugin.Free
  ( runPlugin
  , execPlugin
  , Env(..)
  ) where

import Core.Plugin.Types
import Data.IORef
import qualified Data.Map as Map
import Data.Dynamic
import Control.Monad.Free

-- | Environment for plugin execution
data Env = Env
  { envServices :: IORef (Map.Map String Dynamic)
  , envEvents   :: IORef (Map.Map String [Dynamic -> IO ()])
  , envEffects  :: IORef [IO ()]
  }

-- | Run a plugin in an environment, returning a Disposer
runPlugin :: Env -> Plugin () -> IO Disposer
runPlugin env plugin = do
  actions <- execPlugin env plugin
  return $ Disposer (sequence_ actions)

-- | Execute a plugin and collect cleanup actions
execPlugin :: Env -> Plugin () -> IO [IO ()]
execPlugin env (Pure _) = return []
execPlugin env (Free (RegisterService name val next)) = do
  modifyIORef (envServices env) (Map.insert name val)
  execPlugin env next
execPlugin env (Free (SubscribeEvent name handler next)) = do
  modifyIORef (envEvents env) (Map.insertWith (++) name [handler])
  execPlugin env next
execPlugin env (Free (ProvideEffect acquire next)) = do
  cleanup <- acquire
  modifyIORef (envEffects env) (cleanup :)
  execPlugin env next
execPlugin env (Free (WithContext action k)) = do
  result <- action
  execPlugin env (k result)