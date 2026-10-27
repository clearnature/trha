{-# LANGUAGE ExistentialQuantification #-}

module Core.Plugin.Types
  ( Plugin(..)
  , PluginF(..)
  , PluginName
  , Disposer(..)
  ) where

import Data.Dynamic
import Control.Monad.Free

-- | Plugin name identifier
type PluginName = String

-- | Plugin base functor for Free Monad
data PluginF next
  = RegisterService String Dynamic next
  | SubscribeEvent String (Dynamic -> IO ()) next
  | ProvideEffect (IO (IO ())) next
  | forall a. WithContext (IO a) (a -> next)

instance Functor PluginF where
  fmap f (RegisterService s d next) = RegisterService s d (f next)
  fmap f (SubscribeEvent s h next) = SubscribeEvent s h (f next)
  fmap f (ProvideEffect eff next) = ProvideEffect eff (f next)
  fmap f (WithContext action k) = WithContext action (f . k)

-- | Plugin type using Free Monad
type Plugin = Free PluginF

-- | Disposer for cleanup actions
newtype Disposer = Disposer (IO ())

instance Semigroup Disposer where
  (Disposer a) <> (Disposer b) = Disposer (a >> b)

instance Monoid Disposer where
  mempty = Disposer (return ())