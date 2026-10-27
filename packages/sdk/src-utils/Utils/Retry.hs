{-# LANGUAGE OverloadedStrings #-}

module Utils.Retry
  ( -- * Retry
    RetryConfig(..)
  , defaultRetryConfig
  , withRetry
  , withRetryAsync
  ) where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, try)
import Data.Text (Text)
import qualified Data.Text as T

-- | Retry configuration
data RetryConfig = RetryConfig
  { retryMaxAttempts :: Int
  , retryDelay       :: Int  -- milliseconds
  , retryBackoff     :: Double
  } deriving (Show, Eq)

-- | Default retry configuration
defaultRetryConfig :: RetryConfig
defaultRetryConfig = RetryConfig
  { retryMaxAttempts = 3
  , retryDelay = 1000
  , retryBackoff = 2.0
  }

-- | Retry a computation with exponential backoff
withRetry :: RetryConfig -> IO a -> IO (Either SomeException a)
withRetry config action = do
  result <- try action
  case result of
    Right value -> return $ Right value
    Left ex -> do
      if retryMaxAttempts config > 1
        then do
          let delay = retryDelay config
          let backoff = retryBackoff config
          threadDelay (delay * 1000)  -- Convert to microseconds
          let config' = config { retryMaxAttempts = retryMaxAttempts config - 1
                               , retryDelay = round (fromIntegral delay * backoff)
                               }
          withRetry config' action
        else return $ Left ex

-- | Retry a computation asynchronously (placeholder)
withRetryAsync :: RetryConfig -> IO a -> IO (Either SomeException a)
withRetryAsync = withRetry