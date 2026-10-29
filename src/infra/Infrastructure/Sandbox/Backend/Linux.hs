{-# LANGUAGE OverloadedStrings #-}

-- | Linux backend: bubblewrap argv renderer (docs/plans/sandbox-architecture.md
-- §5.6, T1.1/T1.2).
--
-- Shape: @--ro-bind / /@ makes the whole root read-only, then writable roots
-- and a private @/tmp@ are layered on top. Namespaces come from
-- @--unshare-all@; @--share-net@ re-enables networking for allowlisted policies.
module Infrastructure.Sandbox.Backend.Linux
  ( backend
  , backendIdLinux
  , renderLinux
  , probeLinux
  , sanitizeEnv
  ) where

import Data.List (isPrefixOf)
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

backendIdLinux :: BackendId
backendIdLinux = BackendId "linux-bwrap"

backend :: Backend
backend = Backend
  { backendId = backendIdLinux
  , backendProbe = probeLinux
  , backendRender = renderLinux
  }

-- | Probe bwrap and its unprivileged-userns path. A missing/failed probe is a
-- hard failure; a partial probe still reports the capabilities it has.
probeLinux :: IO (Either SandboxError BackendCapabilities)
probeLinux = do
  found <- findExecutable "bwrap"
  case found of
    Nothing -> pure (Left (SandboxUnavailable backendIdLinux "bwrap not found in PATH"))
    Just _ -> do
      probed <- timeout 5000000 $
        readProcessWithExitCode "bwrap"
          [ "--ro-bind", "/", "/", "--unshare-all", "--", "true" ] ""
      pure $ case probed of
        Nothing -> Left (SandboxUnavailable backendIdLinux "bwrap probe timed out")
        Just (ExitSuccess, _, _) -> Right capsFull
        Just (ExitFailure _, _, err) -> Right capsPartial
          { bcNotes = ["bwrap probe failed: " <> T.pack (take 200 err)] }

capsFull :: BackendCapabilities
capsFull = BackendCapabilities
  { bcBackend = backendIdLinux
  , bcPlatform = Linux
  , bcCapabilities = Set.fromList
      [ CapFsRead, CapFsWrite, CapNet, CapPid, CapSyscall, CapResource, CapCred ]
  , bcEnforcement = Full
  , bcNotes = []
  }

capsPartial :: BackendCapabilities
capsPartial = capsFull
  { bcEnforcement = Partial
      (PartialReason (Set.fromList [CapSyscall]) "bwrap probe failed")
  }

-- | Pure renderer. Fails closed for 'DangerFullAccess' (needs an explicit
-- root) and for policies the renderer cannot express.
renderLinux :: Scope -> LaunchRequest -> Either SandboxError LaunchPlan
renderLinux scope req = do
  (writable, readable, network, limits) <- policySurface (scPolicy scope)
  let mounts = mountArgs writable readable
      envArgs = environmentArgs scope (lrEnv req)
      quoteArgs = concatMap (\(p, w) ->
                    if w
                      then ["--dir", T.pack p, "--bind", T.pack p, T.pack p]
                      else ["--ro-bind", T.pack p, T.pack p]) mounts
      -- Network egress (ADR-009).  NetworkAllow shares the host netns:
      -- bwrap has no per-domain ACL, the domains are recorded in the plan
      -- and audit only.  NetworkProxy also shares the netns but points the
      -- usual proxy variables at the bridge (best-effort, not an ACL).
      netArgs = case network of
        NetworkOff -> []
        NetworkAllow _ -> ["--share-net"]
        NetworkProxy _ -> ["--share-net"]
      proxyEnv = case network of
        NetworkProxy url ->
          concatMap (\k -> ["--setenv", k, url])
            ["HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy"]
        _ -> []
      -- Memory cap via RLIMIT_AS.  pids is deliberately not mapped to
      -- --nproc: RLIMIT_NPROC counts the *host* uid's processes, so any value
      -- below the host's process count makes bwrap's clone fail with EAGAIN
      -- (measured: host 251724).  A real pids cap needs cgroup v2 (ADR-008).
      limiter
        | rlMemoryMiB limits > 0 =
            [ "prlimit"
            , "--as=" <> T.pack (show (rlMemoryMiB limits * 1024 * 1024))
            , "--"
            ]
        | otherwise = []
      args = limiter <> ("bwrap" : ["--ro-bind", "/", "/", "--dev", "/dev", "--proc", "/proc", "--tmpfs", "/tmp"]
          <> quoteArgs
          <> ["--unshare-all"]
          <> netArgs
          <> ["--new-session", "--die-with-parent"]
          <> ["--chdir", T.pack (unAbsolutePath (lrCwd req))]
          <> envArgs
          <> proxyEnv
          <> ["--"]
          <> lrArgv req)
  pure LaunchPlan
    { lpBackend = backendIdLinux
    , lpArgv = args
    , lpEnforcement = Full
    , lpMounts =
        [ MountSpec (AbsolutePath "/") (AbsolutePath "/") MountReadOnly ]
        <> [ MountSpec (AbsolutePath p) (AbsolutePath p)
               (if w then MountReadWrite else MountReadOnly)
           | (p, w) <- mounts ]
    , lpNetwork = network
    , lpLimits = limits
    }

-- | Which paths are writable/read-only, plus network and limits.
policySurface :: Policy
              -> Either SandboxError ([(FilePath, Bool)], [FilePath], NetworkPolicy, ResourceLimits)
policySurface policy = case policy of
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

-- | Deduplicate mounts; a writable entry wins over a read-only one.
mountArgs :: [(FilePath, Bool)] -> [FilePath] -> [(FilePath, Bool)]
mountArgs writable readable = dedupe (writable <> map (\p -> (p, False)) readable)
  where
    dedupe = foldr step []
    step (p, w) acc
      | any ((== p) . fst) acc = acc
      | otherwise = (p, w) : acc

-- | Env is filtered: credentials never enter the sandbox, and PATH/HOME always
-- have a sane default. HOME points at the scope's scratch directory so tools
-- that write caches stay inside the writable bind.
environmentArgs :: Scope -> [(Text, Text)] -> [Text]
environmentArgs scope env =
  ["--clearenv"]
    <> concatMap setArg (("PATH", defaultPath) : ("HOME", homeDir) : filter keep env)
  where
    defaultPath = "/usr/local/bin:/usr/bin:/bin"
    homeDir = case scPolicy scope of
      WorkspaceWrite wr -> T.pack (unAbsolutePath (unExclusivePath (wrScratch wr)))
      _ -> "/tmp"
    keep (k, _) = T.toUpper k /= "HOME" && not (blocked k)
    setArg (k, v) = ["--setenv", k, v]

blocked :: Text -> Bool
blocked key =
  upper `elem` blockedNames
    || any (\p -> p `T.isPrefixOf` upper) blockedPrefixes
  where
    upper = T.toUpper key

blockedNames :: [Text]
blockedNames =
  [ "SSH_AUTH_SOCK", "GPG_AGENT_INFO", "GIT_ASKPASS", "KUBECONFIG"
  , "DOCKER_CONFIG", "NETRC", "AWS_SESSION_TOKEN"
  ]

blockedPrefixes :: [Text]
blockedPrefixes =
  [ "SSH_", "AWS_", "GOOGLE_", "AZURE_", "GCP_", "GITHUB_", "GITLAB_"
  , "KUBE", "DOCKER_", "OPENAI_", "ANTHROPIC_", "DEEPSEEK_"
  ]

-- | Exposed for tests: filter a caller-provided environment.
sanitizeEnv :: [(Text, Text)] -> [(Text, Text)]
sanitizeEnv = filter (not . blocked . fst)
