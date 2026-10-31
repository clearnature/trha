{-# LANGUAGE OverloadedStrings #-}

-- | OpenBSD backend: pledge(2) + unveil(2) (P5/T5.2).
--
-- Both syscalls must be called by the process itself, so a launcher is
-- required — same split as Windows/FreeBSD: this module renders a pure,
-- testable argv; @trha-sandbox-obsd@ performs the pledge/unveil calls.
--
-- The rendered argv is deliberately *semantic* (`--pledge "stdio rpath …"`,
-- `--unveil "path:perms"`) so the promise set is asserted by a golden test
-- rather than hidden inside the launcher.
module Infrastructure.Sandbox.Backend.OpenBSD
  ( backend
  , backendIdOpenBSD
  , launcherBinary
  , renderOpenBSD
  , probeOpenBSD
  , openBSDCaps
  , pledgePromises
  , unveilEntries
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

backendIdOpenBSD :: BackendId
backendIdOpenBSD = BackendId "openbsd-pledge"

-- | The pledge/unveil launcher the runner spawns on OpenBSD.
launcherBinary :: FilePath
launcherBinary = "trha-sandbox-obsd"

backend :: Backend
backend = Backend
  { backendId = backendIdOpenBSD
  , backendProbe = probeOpenBSD
  , backendRender = renderOpenBSD
  }

-- | pledge only filters *classes* of syscalls; it cannot say "this directory
-- but not that one" (that is unveil's job, and unveil is per-path). Partial.
openBSDCaps :: BackendCapabilities
openBSDCaps = BackendCapabilities
  { bcBackend = backendIdOpenBSD
  , bcPlatform = OpenBSD
  , bcCapabilities = Set.fromList [CapFsRead, CapFsWrite, CapNet, CapPid, CapSyscall]
  , bcEnforcement = Partial (PartialReason (Set.fromList [CapResource])
      "pledge/unveil filter syscalls and paths; no resource limits; launcher pending")
  , bcNotes =
      [ "launcher: " <> T.pack launcherBinary <> " (not written yet)"
      , "enforcement: partial — pledge is syscall-class, unveil is per-path"
      ]
  }

probeOpenBSD :: IO (Either SandboxError BackendCapabilities)
probeOpenBSD
  | os /= "openbsd" =
      pure (Left (SandboxUnavailable backendIdOpenBSD
        "openbsd backend requires OpenBSD (the pledge launcher cannot run here)"))
  | otherwise = do
      found <- findExecutable launcherBinary
      pure $ case found of
        Nothing -> Left (SandboxUnavailable backendIdOpenBSD
          ("launcher not found in PATH: " <> T.pack launcherBinary))
        Just _ -> Right openBSDCaps

-- | Render the launcher's argv:
--
-- > trha-sandbox-obsd --pledge "stdio rpath …" --unveil "WS:rw" … -- ARGV...
renderOpenBSD :: Scope -> LaunchRequest -> Either SandboxError LaunchPlan
renderOpenBSD scope req = do
  (policy, network) <- case scPolicy scope of
    DangerFullAccess -> Left (PolicyRejected
      "danger-full-access cannot be rendered; construct a concrete policy")
    ReadOnly ro -> Right (scPolicy scope, roNetwork ro)
    WorkspaceWrite wr -> Right (scPolicy scope, wrNetwork wr)
  let workspace = case scPolicy scope of
        WorkspaceWrite wr -> unAbsolutePath (wrRoot wr)
        _ -> unAbsolutePath (lrCwd req)
      scratch = unAbsolutePath (unExclusivePath (scScratch scope))
      limits = case scPolicy scope of
        WorkspaceWrite wr -> wrLimits wr
        _ -> defaultResourceLimits
      unveils = concatMap (\e -> ["--unveil", e]) (unveilEntries policy workspace scratch)
      argv =
        [ T.pack launcherBinary
        , "--pledge", pledgePromises policy network
        ]
          <> unveils
          <> ["--"] <> lrArgv req
  pure LaunchPlan
    { lpBackend = backendIdOpenBSD
    , lpArgv = argv
    , lpEnforcement = bcEnforcement openBSDCaps
    , lpMounts = []
    , lpNetwork = network
    , lpLimits = limits
    }

-- | The promise set for a policy. @proc exec@ is always needed: the launcher
-- must be able to exec the requested command.
pledgePromises :: Policy -> NetworkPolicy -> Text
pledgePromises policy network = T.intercalate " " (base <> netPart)
  where
    base = case policy of
      DangerFullAccess -> []
      ReadOnly _ -> ["stdio", "rpath", "proc", "exec"]
      WorkspaceWrite _ -> ["stdio", "rpath", "wpath", "cpath", "proc", "exec"]
    netPart = case network of
      NetworkOff -> []
      _ -> ["inet"]

-- | @path:perms@ entries for unveil. Workspace gets read-write only under
-- workspace-write; system paths stay read-only.
unveilEntries :: Policy -> FilePath -> FilePath -> [Text]
unveilEntries policy workspace scratch = wsEntry <> [scratchEntry] <> systemEntries
  where
    wsPerms = case policy of
      WorkspaceWrite _ -> ":rw"
      _ -> ":r"
    wsEntry = [T.pack workspace <> wsPerms]
    scratchEntry = T.pack scratch <> ":rw"
    systemEntries = map (<> ":r") ["/etc", "/usr", "/bin", "/sbin"]
