{-# LANGUAGE OverloadedStrings #-}

-- | Sandbox policy: the platform-independent core of the sandbox seam.
--
-- Design rules (docs/plans/sandbox-architecture.md §5.2):
--
--   * 'DangerFullAccess' has no 'Default' instance and can only be built
--     explicitly.
--   * 'narrow' only ever removes permissions: a child policy is a subset of
--     its parent, and widening requests return 'Nothing'.
--   * 'Enforcement' carries 'Partial' with the missing capabilities and
--     'None' for platforms without an OS sandbox; there is no upgrade path
--     from 'Partial' to 'Full'.
module Infrastructure.Sandbox.Policy
  ( -- * Paths
    AbsolutePath(..)
  , ExclusivePath(..)
    -- * Network and resources
  , NetworkPolicy(..)
  , ResourceLimits(..)
    -- * Policies
  , ReadOnlyPolicy(..)
  , WritableRoot(..)
  , Policy(..)
  , emptyReadOnlyPolicy
  , defaultResourceLimits
    -- * Capabilities and enforcement
  , Capability(..)
  , Enforcement(..)
  , PartialReason(..)
  , policyCapabilities
  , narrowerNetwork
  , isUnder
  , isUnderAny
    -- * Narrowing
  , narrow
  ) where

import Data.List (isPrefixOf)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import System.FilePath (addTrailingPathSeparator, normalise)

-- | An absolute path in the execution world. Callers are responsible for
-- canonicalisation before constructing one; platform backends re-check it.
newtype AbsolutePath = AbsolutePath { unAbsolutePath :: FilePath }
  deriving (Eq, Ord, Show)

-- | A directory only this scope may write to.
newtype ExclusivePath = ExclusivePath { unExclusivePath :: AbsolutePath }
  deriving (Eq, Ord, Show)

-- | Egress policy. Defaults to 'NetworkOff' in the shipped configuration.
data NetworkPolicy
  = NetworkOff
  | NetworkAllow [Text]
  | NetworkProxy Text
  deriving (Eq, Show)

data ResourceLimits = ResourceLimits
  { rlPids      :: Int
  , rlMemoryMiB :: Int
  , rlWallMs    :: Int
  } deriving (Eq, Show)

-- | Shipped defaults.  @0@ means "no limit".
--
-- pids defaults to 512 (fork-bomb containment, best-effort: RLIMIT_NPROC is
-- per-user and a user-namespace root may bypass it).  Memory stays 0 because
-- RLIMIT_AS caps *virtual* memory and GHC/Node reserve far more than their
-- RSS; a limit here silently breaks real builds.  Set it explicitly for
-- untrusted workloads.
defaultResourceLimits :: ResourceLimits
defaultResourceLimits = ResourceLimits
  { rlPids = 0      -- not enforced on Linux (RLIMIT_NPROC is per host uid)
  , rlMemoryMiB = 0  -- opt-in: RLIMIT_AS caps virtual memory
  , rlWallMs = 600000
  }

data ReadOnlyPolicy = ReadOnlyPolicy
  { roReadableRoots :: [AbsolutePath]
  , roNetwork       :: NetworkPolicy
  , roEnvAllow      :: [Text]
  } deriving (Eq, Show)

emptyReadOnlyPolicy :: ReadOnlyPolicy
emptyReadOnlyPolicy = ReadOnlyPolicy
  { roReadableRoots = []
  , roNetwork = NetworkOff
  , roEnvAllow = ["PATH", "HOME", "LANG", "TERM"]
  }

data WritableRoot = WritableRoot
  { wrRoot     :: AbsolutePath
  , wrScratch  :: ExclusivePath
  , wrReadOnly :: [AbsolutePath]
  , wrNetwork  :: NetworkPolicy
  , wrLimits   :: ResourceLimits
  } deriving (Eq, Show)

-- | The three execution policies. There is deliberately no fourth
-- "shared/none" constructor: running without a backend is a launch-time
-- failure ('SandboxUnavailable'), not a policy.
data Policy
  = ReadOnly ReadOnlyPolicy
  | WorkspaceWrite WritableRoot
  | DangerFullAccess
  deriving (Eq, Show)

-- | Platform-independent capability vocabulary (§5.7.2).
data Capability
  = CapFsRead
  | CapFsWrite
  | CapNet
  | CapPid
  | CapSyscall
  | CapResource
  | CapCred
  deriving (Eq, Ord, Show, Enum, Bounded)

data PartialReason = PartialReason
  { prMissing :: Set Capability
  , prNote    :: Text
  } deriving (Eq, Show)

-- | Reported enforcement level. 'None' means the platform has no OS sandbox
-- (iOS/RTOS) and command execution must be refused.
data Enforcement
  = Full
  | Partial PartialReason
  | None Text
  deriving (Eq, Show)

-- | Capabilities a policy asks the backend to guarantee.
policyCapabilities :: Policy -> Set Capability
policyCapabilities policy = case policy of
  DangerFullAccess -> Set.empty
  ReadOnly ro -> Set.fromList $
    [CapFsRead, CapCred] <> netCaps (roNetwork ro)
  WorkspaceWrite wr -> Set.fromList $
    [CapFsRead, CapFsWrite, CapResource, CapCred] <> netCaps (wrNetwork wr)

netCaps :: NetworkPolicy -> [Capability]
netCaps NetworkOff = [CapNet]
netCaps (NetworkAllow _) = [CapNet]
netCaps (NetworkProxy _) = [CapNet]

-- | @isUnder parent child@: @child@ is @parent@ or below it, after
-- normalisation. Case-folding and symlink resolution belong to the platform
-- backend (Windows re-checks with @GetFinalPathNameByHandle@).
isUnder :: AbsolutePath -> AbsolutePath -> Bool
isUnder (AbsolutePath parent) (AbsolutePath child) =
  childNorm == parentNorm || addTrailingPathSeparator parentNorm `isPrefixOf` childNorm
  where
    parentNorm = normalise parent
    childNorm = normalise child

isUnderAny :: [AbsolutePath] -> AbsolutePath -> Bool
isUnderAny roots p = any (`isUnder` p) roots

-- | Narrow a child policy against its parent. 'Nothing' means the child asked
-- for something the parent does not grant.
narrow :: Policy -> Policy -> Maybe Policy
narrow parent child = case (parent, child) of
  (DangerFullAccess, DangerFullAccess) -> Just DangerFullAccess
  -- Tightening from full access needs an explicit root; the caller must
  -- construct a concrete policy instead of relying on an implicit default.
  (DangerFullAccess, _) -> Nothing
  (_, DangerFullAccess) -> Nothing
  (ReadOnly p, ReadOnly c) -> ReadOnly <$> narrowReadOnly p c
  (ReadOnly _, WorkspaceWrite _) -> Nothing
  (WorkspaceWrite p, ReadOnly c) ->
    let readable = wrRoot p : wrReadOnly p
     in ReadOnly <$> narrowReadOnly
          (ReadOnlyPolicy readable (wrNetwork p) ["PATH", "HOME", "LANG", "TERM"])
          c
  (WorkspaceWrite p, WorkspaceWrite c) -> WorkspaceWrite <$> narrowWritable p c

narrowReadOnly :: ReadOnlyPolicy -> ReadOnlyPolicy -> Maybe ReadOnlyPolicy
narrowReadOnly parent child
  | not (all (isUnderAny (roReadableRoots parent)) (roReadableRoots child)) = Nothing
  | not (all (`elem` roEnvAllow parent) (roEnvAllow child)) = Nothing
  | otherwise = do
      network <- narrowerNetwork (roNetwork parent) (roNetwork child)
      pure ReadOnlyPolicy
        { roReadableRoots = roReadableRoots child
        , roNetwork = network
        , roEnvAllow = roEnvAllow child
        }

narrowWritable :: WritableRoot -> WritableRoot -> Maybe WritableRoot
narrowWritable parent child
  | not (isUnder (wrRoot parent) (wrRoot child)) = Nothing
  | not (isUnder (wrRoot child) (unExclusivePath (wrScratch child))) = Nothing
  | not (all (isUnderAny (wrRoot parent : wrReadOnly parent)) (wrReadOnly child)) = Nothing
  | not (limitsWithin (wrLimits parent) (wrLimits child)) = Nothing
  | otherwise = do
      network <- narrowerNetwork (wrNetwork parent) (wrNetwork child)
      pure child { wrNetwork = network }

limitsWithin :: ResourceLimits -> ResourceLimits -> Bool
limitsWithin parent child =
  within (rlPids parent) (rlPids child)
    && within (rlMemoryMiB parent) (rlMemoryMiB child)
    && within (rlWallMs parent) (rlWallMs child)
  where
    -- 0 = no limit.  A child cannot drop a limit its parent imposed.
    within p c
      | p == 0 = True
      | c == 0 = False
      | otherwise = c <= p

-- | The child network policy must be a subset of the parent's.
narrowerNetwork :: NetworkPolicy -> NetworkPolicy -> Maybe NetworkPolicy
narrowerNetwork parent child = case (parent, child) of
  (NetworkOff, NetworkOff) -> Just NetworkOff
  (NetworkOff, _) -> Nothing
  (NetworkAllow _, NetworkOff) -> Just NetworkOff
  (NetworkAllow xs, NetworkAllow ys)
    | all (`elem` xs) ys -> Just (NetworkAllow ys)
    | otherwise -> Nothing
  (NetworkProxy _, NetworkOff) -> Just NetworkOff
  (NetworkProxy x, NetworkProxy y) | x == y -> Just (NetworkProxy y)
  (NetworkAllow _, NetworkProxy _) -> Nothing
  (NetworkProxy _, NetworkAllow _) -> Nothing
  (NetworkProxy _, NetworkProxy _) -> Nothing
