{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Run log under @~/.trha/logs/@.
--
-- One file per day (@trha-YYYYMMDD.log@, 0600) with a line per start/exit.
-- Deliberately tiny: the shell writes what it knows (mode, model, workspace)
-- and never lets a logging failure affect the run.
module Core.RunLog
  ( logDir
  , logLine
  ) where

import Control.Exception (IOException, catch)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import System.Directory (createDirectoryIfMissing)
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import Core.Fs (chmodQuiet)

import Config.Settings (getConfigDir)

-- | @~/.trha/logs@ (@TRHA_LOG_DIR@ overrides, mostly for tests).
logDir :: IO FilePath
logDir = do
  override <- lookupEnv "TRHA_LOG_DIR"
  case override of
    Just p | not (null p) -> pure p
    _ -> (</> "logs") <$> getConfigDir

-- | Append one line to today's log. Never throws.
logLine :: Text -> IO ()
logLine msg = (do
  dir <- logDir
  createDirectoryIfMissing True dir
  chmodQuiet dir 0o700
  now <- getCurrentTime
  let day = formatTime defaultTimeLocale "%Y%m%d" now
      stamp = formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" now
      path = dir </> ("trha-" <> day <> ".log")
  TIO.appendFile path (T.pack stamp <> " " <> msg <> "\n")
  chmodQuiet path 0o600) `catch` \(_ :: IOException) -> pure ()
