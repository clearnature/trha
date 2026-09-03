module Core.Cache.Types
  ( CacheKey
  , CacheStats(..)
  ) where

import Data.ByteString (ByteString)

-- | Cache key type
type CacheKey = ByteString

-- | Cache statistics
data CacheStats = CacheStats
  { cacheHits    :: Int
  , cacheMisses  :: Int
  , cacheSize    :: Int
  , hitRate      :: Double
  } deriving (Show, Eq)