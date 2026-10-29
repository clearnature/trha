{-# LANGUAGE OverloadedStrings #-}

-- | macOS backend (Seatbelt / @sandbox-exec@, T3.1).
--
-- The profile is generated from the same 'Policy' as the Linux renderer:
-- deny writes by default, allow them under the writable roots, and deny
-- network unless the policy allows it.  @sandbox-exec@ is deprecated but is
-- still present on macOS 10.15+; 'probeMac' turns its absence into a
-- 'SandboxUnavailable' instead of guessing.
module Infrastructure.Sandbox.Backend.Mac
  ( backend
  , backendIdMac
  , probeMac
  , renderMac
  , sbplProfile
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
import System.Exit (ExitCode(..))
import System.Process (readProcessWithExitCode)
import System.Timeout (timeout)

backendIdMac :: BackendId
backendIdMac = BackendId "macos-seatbelt"

backend :: Backend
backend = Backend
  { backendId = backendIdMac
  , backendProbe = probeMac
  , backendRender = renderMac
  }

-- | Seatbelt provides fs/network/process confinement; there is no syscall
-- filter and no rlimit, so CapResource is declared best-effort (wall timeout
-- lives in the runner).
capsFull :: BackendCapabilities
capsFull = BackendCapabilities
  { bcBackend = backendIdMac
  , bcPlatform = Darwin
  , bcCapabilities = Set.fromList
      [ CapFsRead, CapFsWrite, CapNet, CapPid, CapResource, CapCred ]
  , bcEnforcement = Full
  , bcNotes =
      [ "sandbox-exec is deprecated since macOS 10.15; still probed (T3.4)"
      , "resource limits are best-effort (wall timeout only)"
      ]
  }

probeMac :: IO (Either SandboxError BackendCapabilities)
probeMac = do
  found <- findExecutable "sandbox-exec"
  case found of
    Nothing -> pure (Left (SandboxUnavailable backendIdMac "sandbox-exec not found in PATH"))
    Just _ -> do
      probed <- timeout 5000000 $
        readProcessWithExitCode "sandbox-exec"
          ["-p", "(version 1)(allow default)", "true"] ""
      pure $ case probed of
        Nothing -> Left (SandboxUnavailable backendIdMac "sandbox-exec probe timed out")
        Just (ExitSuccess, _, _) -> Right capsFull
        Just (ExitFailure _, _, err) -> Right capsFull
          { bcEnforcement = Partial (PartialReason (Set.singleton CapSyscall)
              ("sandbox-exec probe failed: " <> T.pack (take 200 err))) }

-- | Pure SBPL renderer.  Writes are denied globally and re-allowed under the
-- scope's writable roots (plus /tmp and /dev/null, which every toolchain
-- touches).
renderMac :: Scope -> LaunchRequest -> Either SandboxError LaunchPlan
renderMac scope req = do
  (writable, readable, network, limits) <- surface (scPolicy scope)
  let profile = sbplProfile writable readable network
      -- sandbox-exec has no `--` separator: it takes the profile, then the
      -- command and its argv.  Adding `--` made every probe "fail" (the
      -- binary was treated as the command), which only looked like a pass
      -- for the negative probes.
      argv = ["sandbox-exec", "-p", profile] <> lrArgv req
  pure LaunchPlan
    { lpBackend = backendIdMac
    , lpArgv = argv
    , lpEnforcement = Full
    , lpMounts = []
    , lpNetwork = network
    , lpLimits = limits
    }

-- | Build the Seatbelt profile text.
sbplProfile :: [(FilePath, Bool)] -> [FilePath] -> NetworkPolicy -> Text
-- SBPL evaluates rules in order and the *first* matching rule wins, so the
-- specific allows must precede the blanket deny.  Putting `(deny file-write*)`
-- first shadowed every writable subpath: on the macOS runner the
-- write-workspace probe failed while the three negative probes "passed"
-- (everything was denied, which is what they expected).
sbplProfile writable readable network = T.intercalate "\n" $
  [ "(version 1)"
  , "(allow default)"
  ]
    <> writeRules
    <> [ "(deny file-write*)", networkRule ]
  where
    writeRules
      | null writable = []
      | otherwise =
          [ "(allow file-write* "
              <> T.unwords [ subpath p | (p, _) <- writable ]
              <> " (subpath \"/tmp\") (literal \"/dev/null\"))"
          ]
    networkRule = case network of
      NetworkOff -> "(deny network*)"
      _ -> "(allow network*)"
    subpath p = "(subpath \"" <> T.pack p <> "\")"

-- | Same policy surface as the Linux renderer: writable roots (writable
-- first), read-only roots, network policy and limits.
surface :: Policy -> Either SandboxError ([(FilePath, Bool)], [FilePath], NetworkPolicy, ResourceLimits)
surface policy = case policy of
  DangerFullAccess ->
    Left (PolicyRejected "danger-full-access cannot be rendered; construct a concrete policy")
  ReadOnly ro -> Right
    ( []
    , map unAbsolutePath (roReadableRoots ro)
    , roNetwork ro
    , defaultResourceLimits
    )
  WorkspaceWrite wr -> Right
    ( [ (unAbsolutePath (wrRoot wr), True)
      , (unAbsolutePath (unExclusivePath (wrScratch wr)), True)
      ]
    , map unAbsolutePath (wrReadOnly wr)
    , wrNetwork wr
    , wrLimits wr
    )
