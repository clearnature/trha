{-# LANGUAGE ScopedTypeVariables #-}

-- | Filesystem helpers shared by the CLI's on-disk stores.
--
-- These stores all want hardened permissions (0700 dirs / 0600 files) and all
-- live under @~/.trha@, so they hit the same edge: a home that cannot be
-- chmod-ed (a sandbox guest whose HOME is the scratch dir, a read-only
-- bind-mount, NFS).  Doing it by hand in eight places meant the tolerance was
-- applied inconsistently — some call sites caught the error, some crashed.
module Core.Fs
  ( chmodQuiet
  ) where

import Control.Exception (IOException, try)
import Control.Monad (void)
import System.Posix.Files (setFileMode)
import System.Posix.Types (FileMode)

-- | @chmod@ that tolerates a filesystem which refuses the change.
--
-- Failing here would abort the whole command for a permission bit that is
-- moot anyway: on a read-only mount the mount itself is what protects the
-- data, and on a sandbox scratch dir the directory is already private.
chmodQuiet :: FilePath -> FileMode -> IO ()
chmodQuiet path mode =
  void (try (setFileMode path mode) :: IO (Either IOException ()))
