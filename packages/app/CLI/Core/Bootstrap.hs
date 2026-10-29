{-# LANGUAGE OverloadedStrings #-}

-- | Bring the kernel and scheduler up when they are not already listening.
--
-- @trha@ used to assume both were running and only printed instructions when
-- they were not, which left users starting two processes by hand — and losing
-- them again as soon as that shell went away. The backend is now started on
-- demand: whatever already answers @/health@ is left untouched.
--
-- Child processes are detached (@create_group@ + @NoStream@), so quitting the
-- TUI or killing the launching shell does not take them down.
module Core.Bootstrap
  ( ensureBackend
  , kernelPort
  ) where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, try)
import Control.Monad (unless, void, when)
import Core.HTTP (createHTTPClient, httpGet)
import Core.Types (CLIConfig(..), CLIError)
import Data.Aeson (Value)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import qualified Data.Text as T
import System.Directory (doesFileExist)
import System.Environment (getExecutablePath, lookupEnv)
import System.FilePath (takeDirectory, (</>))
import System.Process
  ( CreateProcess(..), StdStream(NoStream), createProcess, proc )

-- | The kernel's OpenAI-compatible API port (CLI default in "Core.Args").
-- Kept here so the bootstrap and the scheduler agree without passing it around.
kernelPort :: Int
kernelPort = 19433

-- | Make sure both services answer @/health@. Returns the ones it started, in
-- start order (empty when everything was already up).
ensureBackend :: CLIConfig -> IO [Text]
ensureBackend config = do
  started <- newIORef []
  kernelUp <- healthy config "http" kernelPort
  unless kernelUp $ do
    spawnKernel
    ok <- waitHealthy config "http" kernelPort 40
    when ok $ modifyIORef' started (<> ["kernel"])

  schedulerUp <- healthy config (configScheme config) (configPort config)
  unless schedulerUp $ do
    spawned <- spawnScheduler
    ok <-
      if spawned
        then waitHealthy config (configScheme config) (configPort config) 60
        else pure False
    when ok $ modifyIORef' started (<> ["scheduler"])

  readIORef started

-- | One @/health@ probe. A failure of any kind (refused, timeout, bad JSON)
-- means "not up"; that is the question being asked.
healthy :: CLIConfig -> Text -> Int -> IO Bool
healthy config scheme port = do
  r <- try (do
          client <- createHTTPClient scheme "127.0.0.1" port "" 2000 "none"
          httpGet client "/health" :: IO (Either CLIError Value))
    :: IO (Either SomeException (Either CLIError Value))
  pure $ case r of
    Right (Right _) -> True
    _ -> False

waitHealthy :: CLIConfig -> Text -> Int -> Int -> IO Bool
waitHealthy config scheme port attempts = go attempts
  where
    go 0 = pure False
    go n = do
      ok <- healthy config scheme port
      if ok
        then pure True
        else threadDelay 500000 >> go (n - 1)

-- | @trha serve@ from the same binary that is running now.
spawnKernel :: IO ()
spawnKernel = do
  self <- getExecutablePath
  spawnDetached self ["serve", "--kernel-port", show kernelPort] Nothing

-- | @node packages/scheduler/dist/cli.js@ from the repo the binary lives in.
-- Returns False when the entry point cannot be located (installed elsewhere).
spawnScheduler :: IO Bool
spawnScheduler = do
  found <- findSchedulerEntry
  case found of
    Nothing -> pure False
    Just (dir, entry) -> spawnDetached "node" [entry] (Just dir) >> pure True

spawnDetached :: FilePath -> [String] -> Maybe FilePath -> IO ()
spawnDetached cmd args mcwd = do
  _ <- try (void $ createProcess (proc cmd args)
    { cwd = mcwd
    , std_in = NoStream
    , std_out = NoStream
    , std_err = NoStream
    , create_group = True
    }) :: IO (Either SomeException ())
  pure ()

-- | Locate the scheduler entry point. @TRHA_SCHEDULER_ENTRY@ wins; otherwise
-- walk up from the executable looking for @packages/scheduler/dist/cli.js@
-- (the dist-newstyle layout nests the binary deep inside the repo).
findSchedulerEntry :: IO (Maybe (FilePath, FilePath))
findSchedulerEntry = do
  override <- lookupEnv "TRHA_SCHEDULER_ENTRY"
  case override of
    Just p | not (null p) -> pure (Just (takeDirectory p, p))
    _ -> do
      self <- try getExecutablePath :: IO (Either SomeException FilePath)
      case self of
        Left _ -> pure Nothing
        Right path -> search (takeDirectory path) (12 :: Int)
  where
    search _ 0 = pure Nothing
    search dir n = do
      let base = dir </> "packages" </> "scheduler"
          entry = base </> "dist" </> "cli.js"
      ok <- doesFileExist entry
      if ok
        then pure (Just (base, entry))
        else search (takeDirectory dir) (n - 1)
