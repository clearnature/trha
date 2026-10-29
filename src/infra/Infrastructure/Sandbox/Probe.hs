{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Runtime probes (T1.5): positive/negative checks that the boundary is
-- actually enforced. Each probe runs through the normal renderer, so a probe
-- can never use a weaker path than a real tool call.
module Infrastructure.Sandbox.Probe
  ( Probe(..)
  , ProbeExpect(..)
  , defaultProbes
  , macProbes
  , windowsProbes
  , windowsReadOnlyProbes
  , runProbes
  , runProbesWith
  , runProbe
  ) where

import Control.Exception (SomeException, try)
import Control.Monad (filterM)
import Data.Text (Text)
import qualified Data.Text as T
import Infrastructure.Sandbox.Backend (Backend, BackendCapabilities, planWith)
import Infrastructure.Sandbox.Error
import Infrastructure.Sandbox.Plan
import Infrastructure.Sandbox.Policy
import Infrastructure.Sandbox.Scope
import System.Directory (doesDirectoryExist, getHomeDirectory)
import System.Exit (ExitCode(..))
import System.FilePath ((</>))
import System.Info (os)
import System.Process (readProcessWithExitCode)

data ProbeExpect = ExpectSuccess | ExpectFailure
  deriving (Eq, Show)

data Probe = Probe
  { prId      :: Text
  , prCommand :: Text
  , prExpect  :: ProbeExpect
  } deriving (Eq, Show)

-- | The P1 probe set. Paths are relative to the workspace; the write probe
-- targets a path outside it on purpose.
defaultProbes :: [Probe]
defaultProbes =
  [ Probe "write-workspace" "touch .trha-probe" ExpectSuccess
  , Probe "write-etc" "touch /etc/trha-probe" ExpectFailure
  , Probe "read-ssh" "cat \"%HOST_HOME%/.ssh/id_rsa\"" ExpectFailure
  , Probe "network" "getent hosts example.com" ExpectFailure
  ]

-- | Windows probe set (T4.6). Commands are `cmd.exe /c` syntax; `runProbe`
-- picks the platform shell, so each probe still goes through `renderWindows`
-- and can never take a weaker path than a real tool call.
--
-- `write-workspace` must succeed under workspace-write; `write-system` and
-- `read-user-secret` must fail. A junction pointing outside the workspace is
-- the T4.5 escape hatch: it has to fail too.
windowsProbes :: [Probe]
windowsProbes =
  [ Probe "write-workspace" "echo probe> .trha-probe" ExpectSuccess
  , Probe "write-system" "echo probe > C:\\Windows\\trha-probe" ExpectFailure
  , Probe "read-user-secret" "type \"%USERPROFILE%\\.ssh\\id_rsa\"" ExpectFailure
  , Probe "junction-escape" "type \"%TRHA_JUNCTION%\\trha-probe-outside\"" ExpectFailure
  , Probe "network" "curl -s --max-time 3 https://example.com" ExpectFailure
  ]

-- | The same set under `read-only`: even the workspace write must fail.
windowsReadOnlyProbes :: [Probe]
windowsReadOnlyProbes =
  [ Probe "write-workspace" "echo probe> .trha-probe" ExpectFailure
  , Probe "write-system" "echo probe > C:\\Windows\\trha-probe" ExpectFailure
  , Probe "read-user-secret" "type \"%USERPROFILE%\\.ssh\\id_rsa\"" ExpectFailure
  , Probe "junction-escape" "type \"%TRHA_JUNCTION%\\trha-probe-outside\"" ExpectFailure
  , Probe "network" "curl -s --max-time 3 https://example.com" ExpectFailure
  ]


runProbes backend caps scope = runProbesWith backend caps scope defaultProbes

runProbesWith :: Backend -> BackendCapabilities -> Scope -> [Probe] -> IO [ProbeResult]
runProbesWith backend caps scope probes =
  mapM (runProbe backend caps scope) probes

-- | macOS variant: @getent@ does not exist there, so the network probe uses
-- curl.  The rest matches the Linux set.
macProbes :: [Probe]
macProbes =
  [ Probe "write-workspace" "touch .trha-probe" ExpectSuccess
  , Probe "write-etc" "touch /etc/trha-probe" ExpectFailure
  , Probe "read-ssh" "cat \"%HOST_HOME%/.ssh/id_rsa\"" ExpectFailure
  , Probe "network" "curl -s --max-time 3 https://example.com" ExpectFailure
  ]

runProbe :: Backend -> BackendCapabilities -> Scope -> Probe -> IO ProbeResult
runProbe backend caps scope probe = do
  hostHome <- getHomeDirectory
  deny <- existingDenyReads hostHome
  let probe' = probe
        { prCommand = T.replace "%HOST_HOME%" (T.pack hostHome) (prCommand probe) }
      request = LaunchRequest
        { lrArgv = probeShell <> [prCommand probe']
        , lrCwd = workspaceOf (scPolicy scope)
        , lrEnv = []
        , lrStdin = StdinClosed
        , lrTimeoutMs = Just 15000
        , lrDenyReads = deny
        , lrDenyFiles = []
        }
  case planWith backend caps scope request of
    Left err -> pure (result probe' False (renderError err))
    Right plan -> case lpArgv plan of
      [] -> pure (result probe' False "empty argv")
      (cmd : args) -> do
        attempted <- try (readProcessWithExitCode (T.unpack cmd) (map T.unpack args) "")
        pure $ case attempted of
          Left (e :: SomeException) -> result probe' False (T.pack (show e))
          Right (code, out, err) ->
            let ok = matches (prExpect probe) code
             in (result probe' ok (clip (if ok then out else err)))
                  { probeExpected = expectText (prExpect probe) }

-- | Existing credential dirs of the *host* home.  Probes use the host path
-- deliberately: `$HOME` inside the sandbox is the scratch dir, so a probe that
-- reads `$HOME/.ssh` would pass without proving anything.
existingDenyReads :: FilePath -> IO [AbsolutePath]
existingDenyReads home = do
  present <- filterM (doesDirectoryExist . (home </>)) defaultDenyReads
  pure (map (AbsolutePath . (home </>)) present)

-- Windows has no bash: the helper's one-shot form runs the command under
-- cmd.exe, so the probe strings use cmd syntax there.
probeShell :: [Text]
probeShell
  | os == "mingw32" = ["cmd.exe", "/c"]
  | otherwise = ["bash", "-lc"]

result :: Probe -> Bool -> Text -> ProbeResult
result probe ok actual = ProbeResult
  { probeName = prId probe
  , probeOk = ok
  , probeExpected = expectText (prExpect probe)
  , probeActual = actual
  }

matches :: ProbeExpect -> ExitCode -> Bool
matches ExpectSuccess ExitSuccess = True
matches ExpectFailure code = code /= ExitSuccess
matches ExpectSuccess _ = False

expectText :: ProbeExpect -> Text
expectText ExpectSuccess = "success"
expectText ExpectFailure = "failure"

renderError :: SandboxError -> Text
renderError err = case err of
  SandboxUnavailable bid msg -> "sandbox unavailable (" <> T.pack (show bid) <> "): " <> msg
  PolicyRejected msg -> "policy rejected: " <> msg
  RenderFailed msg -> "render failed: " <> msg
  LaunchFailed msg -> "launch failed: " <> msg
  ProbeFailed results -> "probe failed: " <> T.pack (show results)

workspaceOf :: Policy -> AbsolutePath
workspaceOf policy = case policy of
  ReadOnly ro -> case roReadableRoots ro of
    (p : _) -> p
    [] -> AbsolutePath "/"
  WorkspaceWrite wr -> wrRoot wr
  DangerFullAccess -> AbsolutePath "/"

clip :: String -> Text
clip = T.take 500 . T.pack
