{-# LANGUAGE OverloadedStrings #-}

-- | Launch plan types: the boundary between policy and a platform backend.
module Infrastructure.Sandbox.Plan
  ( LaunchRequest(..)
  , StdinMode(..)
  , MountMode(..)
  , MountSpec(..)
  , LaunchPlan(..)
  ) where

import Data.Text (Text)
import Infrastructure.Sandbox.Error (BackendId)
import Infrastructure.Sandbox.Policy (AbsolutePath, Enforcement, NetworkPolicy, ResourceLimits)

data StdinMode = StdinClosed | StdinPipe | StdinInherit
  deriving (Eq, Show)

data MountMode = MountReadOnly | MountReadWrite
  deriving (Eq, Show)

data MountSpec = MountSpec
  { msSource :: AbsolutePath
  , msTarget :: AbsolutePath
  , msMode   :: MountMode
  } deriving (Eq, Show)

data LaunchRequest = LaunchRequest
  { lrArgv      :: [Text]
  , lrCwd       :: AbsolutePath
  , lrEnv       :: [(Text, Text)]
  , lrStdin     :: StdinMode
  , lrTimeoutMs :: Maybe Int
  , lrDenyReads :: [AbsolutePath]
    -- ^ Directories the backend must hide from the guest (an empty tmpfs is
    -- mounted over each).  The caller filters to paths that actually exist:
    -- the renderer is pure and cannot @stat@.
  , lrDenyFiles :: [AbsolutePath]
    -- ^ Credential *files* to hide.  A tmpfs cannot mask a file, so backends
    -- bind @/dev/null@ over these instead.
  } deriving (Eq, Show)

data LaunchPlan = LaunchPlan
  { lpBackend     :: BackendId
  , lpArgv        :: [Text]
  , lpEnforcement :: Enforcement
  , lpMounts      :: [MountSpec]
  , lpNetwork     :: NetworkPolicy
  , lpLimits      :: ResourceLimits
  } deriving (Eq, Show)
