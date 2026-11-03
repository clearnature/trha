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
import Core.RunLog (logDir)
import Data.Text (Text)
import qualified Data.Text as T
import System.Directory
  ( createDirectoryIfMissing, doesDirectoryExist, doesFileExist, findExecutable
  , getCurrentDirectory, getModificationTime, listDirectory )
import System.Environment (getEnvironment, getExecutablePath, lookupEnv)
import System.FilePath (takeDirectory, (</>))
import System.IO (IOMode(AppendMode), hClose, openFile)
import System.Process
  ( CreateProcess(..), StdStream(NoStream, UseHandle), createProcess, proc
  , readCreateProcessWithExitCode, waitForProcess )
import Data.Time.Clock (UTCTime)
import System.Exit (ExitCode)

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
  spawnDetached "kernel" [] self ["serve", "--kernel-port", show kernelPort] Nothing

-- | @node packages/scheduler/dist/cli.js@ from the repo the binary lives in.
-- Returns False when the entry point cannot be located (installed elsewhere).
--
-- @TRHA_WORKSPACE@ is passed explicitly, and it is the *caller's* cwd, not the
-- scheduler's own directory.  Without it `resolveWorkspace` walks up from
-- @packages/scheduler@ and lands on this repository's `.git` root — so a `trha`
-- started in @/data/test@ reported the source tree as its workspace.
spawnScheduler :: IO Bool
spawnScheduler = do
  found <- findSchedulerEntry
  case found of
    Nothing -> pure False
    Just (dir, entry) -> do
      -- The scheduler runs from dist/; a stale dist silently serves old routes
      -- (that is how /workspace kept answering 404 after its route landed).
      ensureSchedulerFresh dir
      cwd <- getCurrentDirectory
      spawnDetached "scheduler" [("TRHA_WORKSPACE", cwd)] "node" [entry] (Just dir)
      pure True

-- | Rebuild @packages/scheduler/dist@ when any @.ts@ under @src/@ is newer.
--
-- Best effort: a missing npm or a failed build leaves the old dist in place,
-- so the client still starts — it just keeps the old behaviour.
ensureSchedulerFresh :: FilePath -> IO ()
ensureSchedulerFresh base = do
  let distEntry = base </> "dist" </> "cli.js"
  distThere <- doesFileExist distEntry
  if not distThere
    then rebuild
    else do
      distTime <- getModificationTime distEntry
      srcTime <- newestTsTime (base </> "src") (0 :: Int)
      case srcTime of
        Just t | t > distTime -> rebuild
        _ -> pure ()
  where
    rebuild = void
      (try (readCreateProcessWithExitCode
              ((proc "npm" ["run", "--silent", "build"]) { cwd = Just base }) "")
        :: IO (Either SomeException (ExitCode, String, String)))

-- | Newest modification time of any file under @dir@ (depth-limited).
newestTsTime :: FilePath -> Int -> IO (Maybe UTCTime)
newestTsTime dir depth
  | depth > 8 = pure Nothing
  | otherwise = do
      isDir <- doesDirectoryExist dir
      if not isDir
        then pure Nothing
        else do
          entries <- listDirectory dir
          times <- mapM one entries
          pure (newest times)
  where
    one e = do
      let p = dir </> e
      isDir <- doesDirectoryExist p
      if isDir
        then newestTsTime p (depth + 1)
        else if ".ts" `T.isSuffixOf` T.pack e || ".json" `T.isSuffixOf` T.pack e
               then Just <$> getModificationTime p
               else pure Nothing
    newest xs = case [ t | Just t <- xs ] of
      [] -> Nothing
      ts -> Just (maximum ts)

-- | Start a service that is *not* our child.
--
-- The kernel and scheduler are shared by the TUI, desktop and web clients, so
-- their lifetime must not be tied to whichever client happened to start them.
-- @setsid -f@ forks into a new session and exits immediately, so the service is
-- reparented to the user's session manager: it outlives this process, and when
-- it is stopped the manager reaps it — no zombie left behind for 'stopService'
-- to mistake for a live process.
--
-- Without this the service was a direct child of the TUI: quitting the TUI
-- looked like an "orphan" and a stopped service sat as a zombie, which made
-- Ctrl+Alt+Q wait out the full 5 s liveness budget per service.
spawnDetached :: Text -> [(String, String)] -> FilePath -> [String] -> Maybe FilePath -> IO ()
spawnDetached name extraEnv cmd args mcwd = do
  dir <- logDir
  createDirectoryIfMissing True dir
  let path = dir </> T.unpack name <> ".log"
  hasSetsid <- findExecutable "setsid"
  let (prog, argv) = case hasSetsid of
        Just _  -> ("setsid", "-f" : cmd : args)
        Nothing -> (cmd, args)   -- no setsid: fall back to a plain spawn
  baseEnv <- getEnvironment
  let -- env = Just replaces the whole environment, so start from ours and
      -- let the explicit entries win.
      childEnv = extraEnv
        <> [ (k, v) | (k, v) <- baseEnv, k `notElem` map fst extraEnv ]
  _ <- try (do
    -- The service's own output goes to ~/.trha/logs/, not /tmp: these logs
    -- have to survive a reboot, and they belong with the rest of the state.
    h <- openFile path AppendMode
    (_, _, _, ph) <- createProcess (proc prog argv)
      { cwd = mcwd
      , env = Just childEnv
      , std_in = NoStream
      , std_out = UseHandle h
      , std_err = UseHandle h
      , create_group = True
      }
    hClose h                  -- the child keeps its own copy of the handle
    -- Only the @setsid -f@ wrapper is short-lived and needs reaping. A direct
    -- spawn (Windows has no setsid) *is* the long-running service, so waiting
    -- here would block the caller forever -- that is exactly why the TUI
    -- stopped at "Starting TUI mode..." on Windows.
    case hasSetsid of
      Just _  -> void (waitForProcess ph)
      Nothing -> pure ()
    pure ()) :: IO (Either SomeException ())
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
