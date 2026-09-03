{-# LANGUAGE OverloadedStrings #-}

module Utils.Logger
  ( -- * Logger
    Logger(..)
  , LogLevel(..)
  , createLogger
  , logMessage
  , logDebug
  , logInfo
  , logWarning
  , logError
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (getCurrentTime, formatTime, defaultTimeLocale)

-- | Log level
data LogLevel
  = Debug
  | Info
  | Warning
  | Error
  deriving (Show, Eq, Ord)

-- | Logger
data Logger = Logger
  { loggerLevel :: LogLevel
  , loggerPrefix :: Text
  }

-- | Create a new logger
createLogger :: LogLevel -> Text -> Logger
createLogger level prefix = Logger level prefix

-- | Log a message
logMessage :: Logger -> LogLevel -> Text -> IO ()
logMessage logger level message = do
  if level >= loggerLevel logger
    then do
      time <- getCurrentTime
      let timeStr = T.pack $ formatTime defaultTimeLocale "%Y-%m-%d %H:%M:%S" time
      let levelStr = T.pack $ show level
      let prefix = loggerPrefix logger
      putStrLn $ T.unpack $ timeStr <> " [" <> levelStr <> "] " <> prefix <> ": " <> message
    else return ()

-- | Log debug message
logDebug :: Logger -> Text -> IO ()
logDebug logger = logMessage logger Debug

-- | Log info message
logInfo :: Logger -> Text -> IO ()
logInfo logger = logMessage logger Info

-- | Log warning message
logWarning :: Logger -> Text -> IO ()
logWarning logger = logMessage logger Warning

-- | Log error message
logError :: Logger -> Text -> IO ()
logError logger = logMessage logger Error