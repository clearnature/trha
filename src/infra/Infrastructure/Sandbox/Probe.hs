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
  , runProbes
  , runProbesWith
  , runProbe
  ) where

import Control.Exception (SomeException, try)
import Data.Text (Text)
import qualified Data.Text as T
import Infrastructure.Sandbox.Backend (Backend, BackendCapabilities, planWith)
import Infrastructure.Sandbox.Error
import Infrastructure.Sandbox.Plan
import Infrastructure.Sandbox.Policy
import Infrastructure.Sandbox.Scope
import System.Exit (ExitCode(..))
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
  , Probe "read-ssh" "cat \"$HOME/.ssh/id_rsa\"" ExpectFailure
  , Probe "network" "getent hosts example.com" ExpectFailure
  ]

runProbes :: Backend -> BackendCapabilities -> Scope -> IO [ProbeResult]
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
  , Probe "read-ssh" "cat \"$HOME/.ssh/id_rsa\"" ExpectFailure
  , Probe "network" "curl -s --max-time 3 https://example.com" ExpectFailure
  ]

runProbe :: Backend -> BackendCapabilities -> Scope -> Probe -> IO ProbeResult
runProbe backend caps scope probe =
  case planWith backend caps scope request of
    Left err -> pure (result False (renderError err))
    Right plan -> case lpArgv plan of
      [] -> pure (result False "empty argv")
      (cmd : args) -> do
        attempted <- try (readProcessWithExitCode (T.unpack cmd) (map T.unpack args) "")
        pure $ case attempted of
          Left (e :: SomeException) -> result False (T.pack (show e))
          Right (code, out, err) ->
            let ok = matches (prExpect probe) code
             in ProbeResult
                  { probeName = prId probe
                  , probeOk = ok
                  , probeExpected = expectText (prExpect probe)
                  , probeActual = clip (if ok then out else err)
                  }
  where
    request = LaunchRequest
      { lrArgv = ["bash", "-lc", prCommand probe]
      , lrCwd = workspaceOf (scPolicy scope)
      , lrEnv = []
      , lrStdin = StdinClosed
      , lrTimeoutMs = Just 15000
      }
    result ok actual = ProbeResult
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
