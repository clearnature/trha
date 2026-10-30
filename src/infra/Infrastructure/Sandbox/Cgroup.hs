{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}

-- | cgroup v2 pids limits (ADR-008 / T2.3).
--
-- pids cannot be expressed with rlimits: @RLIMIT_NPROC@ counts the *host uid*'s
-- processes, so any value below the host's process count makes bwrap's clone
-- fail with EAGAIN. cgroup v2's pids controller is per-cgroup, which is what a
-- per-scope limit actually needs.
--
-- systemd delegates @user@UID.service@ to the user, so a plain user can create
-- child cgroups there — but only if the pids controller is in the parent's
-- @cgroup.subtree_control@. 'detectCgroup' verifies that by probing, not by
-- assuming.
module Infrastructure.Sandbox.Cgroup
  ( CgroupSupport(..)
  , PidsCgroup
  , cgroupPath
  , detectCgroup
  , createPidsCgroup
  , addProcessTo
  , destroyPidsCgroup
  , detectSystemdRun
  ) where

import Control.Exception (IOException, SomeException, try)
import Control.Monad (filterM)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Directory
  ( createDirectory, doesFileExist, findExecutable, removeDirectory )
import System.Exit (ExitCode(..))
import System.FilePath (takeDirectory, (</>))
#ifndef mingw32_HOST_OS
import System.Posix.Process (getProcessID)
#endif
import System.Process (readProcessWithExitCode)

data CgroupSupport = CgroupSupport
  { csBase  :: FilePath
    -- ^ Deepest cgroup v2 directory this process may create children in.
  , csNotes :: [Text]
  } deriving (Eq, Show)

newtype PidsCgroup = PidsCgroup { cgroupPath :: FilePath }
  deriving (Eq, Show)

cgroupRoot :: FilePath
cgroupRoot = "/sys/fs/cgroup"

-- | Find a delegated cgroup v2 directory that accepts a pids limit.
detectCgroup :: IO (Either Text CgroupSupport)
detectCgroup = do
  mounted <- doesFileExist (cgroupRoot </> "cgroup.controllers")
  if not mounted
    then pure (Left "cgroup v2 not mounted at /sys/fs/cgroup")
    else do
      current <- currentCgroupPath
      case current of
        Nothing -> pure (Left "cannot read /proc/self/cgroup")
        Just path -> do
          let candidates = map toDir (ancestors path)
          writable <- filterM probeDir candidates
          pure $ case writable of
            (base : _) -> Right (CgroupSupport base [T.pack ("cgroup base: " <> base)])
            [] -> Left "no delegated cgroup directory accepts a pids limit"
  where
    toDir "/" = cgroupRoot
    toDir p = cgroupRoot </> dropWhile (== '/') p

-- | From the deepest path to the mount root: @["/a/b", "/a", "/"]@.
ancestors :: FilePath -> [FilePath]
ancestors path = go path
  where
    go "/" = ["/"]
    go q = q : go (takeDirectory q)

currentCgroupPath :: IO (Maybe FilePath)
currentCgroupPath = do
  raw <- try (TIO.readFile "/proc/self/cgroup") :: IO (Either IOException Text)
  pure $ case raw of
    Left _ -> Nothing
    Right txt ->
      case [ T.unpack (last parts)
           | line <- T.lines txt
           , let parts = T.splitOn ":" line
           , ("0" : _) <- [parts]
           , length parts >= 3
           , not (T.null (last parts)) ] of
        (p : _) -> Just p
        [] -> Nothing

#ifdef mingw32_HOST_OS
-- Windows pids containment is the helper's Job Object (T4.4); cgroups never
-- run here, so the detector reports unsupported and callers degrade honestly.
detectCgroup :: IO (Either Text CgroupSupport)
detectCgroup = pure (Left "cgroup v2 is a Linux feature (Windows uses the Job Object)")

detectSystemdRun :: IO Bool
detectSystemdRun = pure False
#else
-- | Can we create a child cgroup here *and* set its pids limit?
probeDir :: FilePath -> IO Bool
probeDir base = do
  pid <- getProcessID
  let probe = base </> ("trha-probe-" <> show pid)
  created <- try (createDirectory probe) :: IO (Either SomeException ())
  case created of
    Left _ -> pure False
    Right _ -> do
      hasPids <- doesFileExist (probe </> "pids.max")
      writable <-
        if not hasPids
          then pure False
          else do
            written <- try (writeFile (probe </> "pids.max") "max\n")
              :: IO (Either IOException ())
            pure (either (const False) (const True) written)
      _ <- try (removeDirectory probe) :: IO (Either SomeException ())
      pure writable

-- | Create @trha-<name>-<pid>@ under the delegated base and set @pids.max@.
createPidsCgroup :: CgroupSupport -> Text -> Int -> IO (Either Text PidsCgroup)
createPidsCgroup support name limit = do
  pid <- getProcessID
  let dir = csBase support </> ("trha-" <> T.unpack name <> "-" <> show pid)
  created <- try (createDirectory dir) :: IO (Either SomeException ())
  case created of
    Left e -> pure (Left (T.pack (show e)))
    Right _ -> do
      written <- try (TIO.writeFile (dir </> "pids.max") (T.pack (show limit) <> "\n"))
        :: IO (Either IOException ())
      case written of
        Left e -> do
          _ <- try (removeDirectory dir) :: IO (Either SomeException ())
          pure (Left (T.pack (show e)))
        Right _ -> pure (Right (PidsCgroup dir))

-- | Move a process (and, by inheritance, its whole tree) into the cgroup.
addProcessTo :: PidsCgroup -> Int -> IO (Either Text ())
addProcessTo (PidsCgroup dir) pid = do
  moved <- try (TIO.writeFile (dir </> "cgroup.procs") (T.pack (show pid) <> "\n"))
    :: IO (Either IOException ())
  pure (either (Left . T.pack . show) Right moved)

-- | Best effort: a leftover process keeps the directory alive (EBUSY) and the
-- next run just picks a new name.
destroyPidsCgroup :: PidsCgroup -> IO ()
destroyPidsCgroup (PidsCgroup dir) = do
  _ <- try (removeDirectory dir) :: IO (Either SomeException ())
  pure ()

-- | Does @systemd-run --user --scope@ work here?
--
-- This is the only reliable way to put a bwrap child into a pids-limited
-- cgroup *before* it forks: bwrap 0.11 has no @--cgroup@, and joining after
-- spawn loses the race (measured: 700 forks succeeded under @pids.max=512@).
-- systemd creates the scope first, so every child inherits the limit.
detectSystemdRun :: IO Bool
detectSystemdRun = do
  found <- findExecutable "systemd-run"
  case found of
    Nothing -> pure False
    Just _ -> do
      r <- try (readProcessWithExitCode "systemd-run"
             ["--user", "--scope", "-p", "TasksMax=4096", "--", "true"] "")
        :: IO (Either SomeException (ExitCode, String, String))
      pure $ case r of
        Right (ExitSuccess, _, _) -> True
        _ -> False
#endif
