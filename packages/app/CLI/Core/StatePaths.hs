{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Where the small state files live.
--
-- They used to sit directly in @~/.trha@ (@frecency.json@, @models.json@,
-- @currency.json@, @stash.jsonl@, @history@).  They now belong in
-- @~/.trha/state/@, keeping the home directory readable as the reference
-- CLIs do — but an upgrade must not lose them, so reads fall back to the
-- legacy location while every write goes to the new one.
module Core.StatePaths
  ( stateReadPath
  , stateWritePath
  , stateLegacyPath
  , migrateLegacy
  ) where

import Control.Exception (IOException, catch)
import System.Directory
    ( copyFile, createDirectoryIfMissing, doesFileExist )
import System.FilePath ((</>))
import Core.Fs (chmodQuiet)

import Config.Settings (getConfigDir)

-- | @~/.trha/state/<name>@.
stateWritePath :: FilePath -> IO FilePath
stateWritePath name = do
  dir <- getConfigDir
  let sdir = dir </> "state"
  createDirectoryIfMissing True sdir
  chmodQuiet sdir 0o700
  pure (sdir </> name)

-- | @~/.trha/<name>@ (where older builds wrote it).
stateLegacyPath :: FilePath -> IO FilePath
stateLegacyPath name = (</> name) <$> getConfigDir

-- | Read path: @state/<name>@ when it exists, else the legacy file when it
-- exists, else the new path (so callers can treat "missing" uniformly).
stateReadPath :: FilePath -> IO FilePath
stateReadPath name = do
  new <- stateWritePath name
  newOk <- doesFileExist new
  if newOk then pure new else do
    old <- stateLegacyPath name
    oldOk <- doesFileExist old
    pure (if oldOk then old else new)

-- | One-time copy of a legacy file to its new location, when the new one is
-- absent.  Best effort (a failed copy just leaves the legacy file in place).
migrateLegacy :: FilePath -> IO ()
migrateLegacy name = do
  new <- stateWritePath name
  old <- stateLegacyPath name
  newOk <- doesFileExist new
  oldOk <- doesFileExist old
  if oldOk && not newOk
    then copyFile old new `catch` \(_ :: IOException) -> pure ()
    else pure ()
