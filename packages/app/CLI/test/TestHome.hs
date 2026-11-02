{-# LANGUAGE OverloadedStrings #-}

-- | A temporary data directory for specs that resolve user paths.
--
-- Swapping @HOME@ is not enough on Windows: 'System.Directory.getHomeDirectory'
-- asks Win32 for the profile folder and never looks at environment variables,
-- which is exactly how @state paths@, @settings resolution@,
-- @recordProjectSession@ and @scanProjectCached@ failed there while passing on
-- Linux.  The specs therefore drive @TRHA_CONFIG_DIR@ -- the override
-- 'Config.Settings.getConfigDir' honours -- and the home variables are swapped
-- too, so POSIX keeps behaving the way it always did.
--
-- hspec runs specs sequentially inside one process, so a single scratch
-- directory is enough; it is wiped on entry and on release (Windows may still
-- hold handles at release, so a failed cleanup is retried and then ignored --
-- it must not fail the spec).
module TestHome (withTempHome) where

import Control.Exception (bracket, SomeException, try)
import System.Directory
    ( createDirectoryIfMissing, getTemporaryDirectory, removePathForcibly )
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.FilePath ((</>))

-- | Run an action with a scratch data directory (returned as the effective
-- home, i.e. @TRHA_CONFIG_DIR@ is @<home>/.trha@), then restore everything.
withTempHome :: (FilePath -> IO a) -> IO a
withTempHome action = bracket acquire release (\(dir, _) -> action dir)
  where
    acquire = do
      base <- getTemporaryDirectory
      let dir = base </> "trha-test-home"
      ignoreIO (removePathForcibly dir)
      createDirectoryIfMissing True dir
      saved <- mapM lookupEnv vars
      setEnv "HOME" dir
      -- Windows: getHomeDirectory ignores this, but other tools read it.
      setEnv "USERPROFILE" dir
      -- The override getConfigDir actually honours on every platform.
      setEnv "TRHA_CONFIG_DIR" (dir </> ".trha")
      pure (dir, saved)
    release (dir, saved) = do
      mapM_ (uncurry restore) (zip vars saved)
      ignoreIO (removePathForcibly dir)
    vars = ["HOME", "USERPROFILE", "TRHA_CONFIG_DIR"]
    restore var value = case value of
      Just v  -> setEnv var v
      Nothing -> unsetEnv var

ignoreIO :: IO () -> IO ()
ignoreIO act = () <$ (try act :: IO (Either SomeException ()))
