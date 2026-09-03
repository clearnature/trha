module Core.Cache.Engine
  ( CacheEngine(..)
  , createCacheEngine
  , cacheLookup
  , cacheInsert
  , cacheStats
  ) where

import Core.Cache.Types
import Data.IORef
import qualified Data.Map as Map
import Data.Dynamic
import Data.ByteString (ByteString)

-- | Cache engine with statistics
data CacheEngine = CacheEngine
  { cacheStore :: IORef (Map.Map CacheKey Dynamic)
  , hitsRef    :: IORef Int
  , missesRef  :: IORef Int
  }

-- | Create a new cache engine
createCacheEngine :: IO CacheEngine
createCacheEngine = do
  storeRef <- newIORef Map.empty
  hitsRef <- newIORef 0
  missesRef <- newIORef 0
  return $ CacheEngine storeRef hitsRef missesRef

-- | Lookup a value in the cache
cacheLookup :: CacheEngine -> CacheKey -> IO (Maybe Dynamic)
cacheLookup engine key = do
  store <- readIORef (cacheStore engine)
  case Map.lookup key store of
    Just val -> do
      modifyIORef (hitsRef engine) (+1)
      return (Just val)
    Nothing -> do
      modifyIORef (missesRef engine) (+1)
      return Nothing

-- | Insert a value into the cache
cacheInsert :: CacheEngine -> CacheKey -> Dynamic -> IO ()
cacheInsert engine key val = do
  modifyIORef (cacheStore engine) (Map.insert key val)

-- | Get cache statistics
cacheStats :: CacheEngine -> IO CacheStats
cacheStats engine = do
  store <- readIORef (cacheStore engine)
  hits <- readIORef (hitsRef engine)
  misses <- readIORef (missesRef engine)
  let total = hits + misses
      rate = if total > 0 then fromIntegral hits / fromIntegral total else 0.0
  return $ CacheStats hits misses (Map.size store) rate