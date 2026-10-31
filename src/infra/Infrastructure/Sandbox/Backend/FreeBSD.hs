{-# LANGUAGE OverloadedStrings #-}

-- | FreeBSD backend: Capsicum (P5/T5.1).
--
-- Capsicum cannot be expressed in bwrap-style argv — a launcher must pre-open
-- the file descriptors and then call @cap_enter@ + @cap_rights_limit@. So the
-- split mirrors Windows (ADR-007): this module is the pure renderer that
-- produces the launcher's argv, and `trha-sandbox-bsd` is the (yet to be
-- written) C launcher that performs the capability dance.
module Infrastructure.Sandbox.Backend.FreeBSD
  ( backend
  , backendIdFreeBSD
  , launcherBinary
  , renderFreeBSD
  , probeFreeBSD
  , freeBSDCaps
  ) where

import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Infrastructure.Sandbox.Backend
import Infrastructure.Sandbox.Error
import Infrastructure.Sandbox.Plan
import Infrastructure.Sandbox.Policy
import Infrastructure.Sandbox.Scope
import System.Directory (findExecutable)
import System.Info (os)

backendIdFreeBSD :: BackendId
backendIdFreeBSD = BackendId "freebsd-capsicum"

-- | The Capsicum launcher the runner spawns on FreeBSD.
launcherBinary :: FilePath
launcherBinary = "trha-sandbox-bsd"

backend :: Backend
backend = Backend
  { backendId = backendIdFreeBSD
  , backendProbe = probeFreeBSD
  , backendRender = renderFreeBSD
  }

-- | Capsicum constrains capabilities of pre-opened descriptors, not paths:
-- a process that still holds a directory fd can do everything that fd allows.
-- That is why the FreeBSD backend is `Partial`, never `Full`.
freeBSDCaps :: BackendCapabilities
freeBSDCaps = BackendCapabilities
  { bcBackend = backendIdFreeBSD
  , bcPlatform = FreeBSD
  , bcCapabilities = Set.fromList [CapFsRead, CapFsWrite, CapNet, CapPid]
  , bcEnforcement = Partial (PartialReason (Set.fromList [CapSyscall])
      "capsicum limits capability use, not path traversal; launcher pending")
  , bcNotes =
      [ "launcher: " <> T.pack launcherBinary <> " (not written yet)"
      , "enforcement: partial — capsicum is capability- not path-based"
      ]
  }

probeFreeBSD :: IO (Either SandboxError BackendCapabilities)
probeFreeBSD
  | os /= "freebsd" =
      pure (Left (SandboxUnavailable backendIdFreeBSD
        "freebsd backend requires FreeBSD (the capsicum launcher cannot run here)"))
  | otherwise = do
      found <- findExecutable launcherBinary
      pure $ case found of
        Nothing -> Left (SandboxUnavailable backendIdFreeBSD
          ("launcher not found in PATH: " <> T.pack launcherBinary))
        Just _ -> Right freeBSDCaps

-- | Render the launcher's argv:
--
-- > trha-sandbox-bsd --workspace WS --scratch S --policy P --network N -- ARGV...
renderFreeBSD :: Scope -> LaunchRequest -> Either SandboxError LaunchPlan
renderFreeBSD scope req = do
  (policyText, network) <- case scPolicy scope of
    DangerFullAccess -> Left (PolicyRejected
      "danger-full-access cannot be rendered; construct a concrete policy")
    ReadOnly ro -> Right ("read-only", roNetwork ro)
    WorkspaceWrite wr -> Right ("workspace-write", wrNetwork wr)
  let workspace = case scPolicy scope of
        WorkspaceWrite wr -> unAbsolutePath (wrRoot wr)
        _ -> unAbsolutePath (lrCwd req)
      scratch = unAbsolutePath (unExclusivePath (scScratch scope))
      limits = case scPolicy scope of
        WorkspaceWrite wr -> wrLimits wr
        _ -> defaultResourceLimits
      argv =
        [ T.pack launcherBinary
        , "--workspace", T.pack workspace
        , "--scratch", T.pack scratch
        , "--policy", policyText
        , "--network", networkText network
        , "--"
        ] <> lrArgv req
  pure LaunchPlan
    { lpBackend = backendIdFreeBSD
    , lpArgv = argv
    , lpEnforcement = bcEnforcement freeBSDCaps
    , lpMounts = []
    , lpNetwork = network
    , lpLimits = limits
    }

networkText :: NetworkPolicy -> Text
networkText NetworkOff = "off"
networkText (NetworkAllow domains) = "allow:" <> T.intercalate "," domains
networkText (NetworkProxy url) = "proxy:" <> url
