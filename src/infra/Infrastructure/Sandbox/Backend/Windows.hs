{-# LANGUAGE OverloadedStrings #-}

-- | Windows backend: the Rust helper (@trha-sandbox-win.exe@) does the Win32
-- work (restricted token, ACL, Job Object); Haskell decides the policy and
-- renders the helper's argv (ADR-007).
--
-- The renderer is pure, so it is fully testable on Linux. Only the helper needs
-- a Windows host — and its enforcement is reported honestly as @Partial@ until
-- the token is carried into spawn (T4.2) and T4.6's probes pass on a real box.
module Infrastructure.Sandbox.Backend.Windows
  ( backend
  , backendIdWindows
  , helperBinary
  , renderWindows
  , probeWindows
  , windowsCaps
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

backendIdWindows :: BackendId
backendIdWindows = BackendId "windows-restricted-token"

-- | The helper executable the runner spawns on Windows.
helperBinary :: FilePath
helperBinary = "trha-sandbox-win.exe"

backend :: Backend
backend = Backend
  { backendId = backendIdWindows
  , backendProbe = probeWindows
  , backendRender = renderWindows
  }

-- | Honest capability report: the helper builds and speaks NDJSON v1, but the
-- restricted token is not carried into spawn yet, so writes are unconstrained.
windowsCaps :: BackendCapabilities
windowsCaps = BackendCapabilities
  { bcBackend = backendIdWindows
  , bcPlatform = Windows
  , bcCapabilities = Set.fromList [CapFsRead, CapFsWrite, CapNet, CapPid, CapResource]
  , bcEnforcement = Partial (PartialReason (Set.fromList [CapFsWrite])
      "restricted token not wired into spawn yet (T4.2/T4.6); writes unconstrained")
  , bcNotes =
      [ "helper: " <> T.pack helperBinary
      , "enforcement: partial until T4.6 probes pass on a Windows host"
      ]
  }

-- | On a non-Windows build the backend is unavailable (fail-closed), mirroring
-- how the stub behaved before the helper existed.
probeWindows :: IO (Either SandboxError BackendCapabilities)
probeWindows
  | os /= "mingw32" =
      pure (Left (SandboxUnavailable backendIdWindows
        "windows backend requires Windows (the helper cannot run here)"))
  | otherwise = do
      found <- findExecutable helperBinary
      pure $ case found of
        Nothing -> Left (SandboxUnavailable backendIdWindows
          ("helper not found in PATH: " <> T.pack helperBinary))
        Just _ -> Right windowsCaps

-- | Render the helper's one-shot invocation:
--
-- > trha-sandbox-win.exe --workspace WS --scratch S --policy P --network N -- ARGV...
renderWindows :: Scope -> LaunchRequest -> Either SandboxError LaunchPlan
renderWindows scope req = do
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
      helperArgs =
        [ T.pack helperBinary
        , "--workspace", T.pack workspace
        , "--scratch", T.pack scratch
        , "--policy", policyText
        , "--network", networkText network
        , "--"
        ] <> lrArgv req
  pure LaunchPlan
    { lpBackend = backendIdWindows
    , lpArgv = helperArgs
    , lpEnforcement = bcEnforcement windowsCaps
    , lpMounts = []
    , lpNetwork = network
    , lpLimits = limits
    }

-- | Wire form shared with the helper's `parse_network` (and with bwrap's).
networkText :: NetworkPolicy -> Text
networkText NetworkOff = "off"
networkText (NetworkAllow domains) = "allow:" <> T.intercalate "," domains
networkText (NetworkProxy url) = "proxy:" <> url
