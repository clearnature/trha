{-# LANGUAGE OverloadedStrings #-}

-- | Golden tests for the Windows renderer (T4.1): the helper invocation is a
-- pure function, so the whole contract is asserted on Linux.
module SandboxWindowsSpec (sandboxWindowsSpec) where

import Data.Text (Text)
import Infrastructure.Sandbox.Backend (BackendCapabilities(..))
import Infrastructure.Sandbox.Backend.Windows (helperBinary, renderWindows, windowsCaps)
import Infrastructure.Sandbox.Plan
import Infrastructure.Sandbox.Policy
import Infrastructure.Sandbox.Probe
  ( Probe(..), ProbeExpect(..), windowsProbes, windowsReadOnlyProbes )
import Infrastructure.Sandbox.Scope
import Test.Hspec

sandboxWindowsSpec :: Spec
sandboxWindowsSpec = describe "windows renderer (T4.1)" $ do
  it "renders the helper one-shot invocation" $ do
    case renderWindows writeScope writeRequest of
      Left e -> expectationFailure (show e)
      Right plan -> do
        lpArgv plan `shouldBe`
          [ "trha-sandbox-win.exe"
          , "--workspace", "C:\\ws"
          , "--scratch", "C:\\scratch"
          , "--policy", "workspace-write"
          , "--network", "off"
          , "--"
          , "cmd.exe", "/c", "echo hi"
          ]
        helperBinary `shouldBe` "trha-sandbox-win.exe"

  it "reports Partial enforcement instead of pretending the token is wired" $ do
    case renderWindows writeScope writeRequest of
      Left e -> expectationFailure (show e)
      Right plan -> lpEnforcement plan `shouldSatisfy` isPartial

  it "renders read-only without writable roots" $ do
    let scope = scopeRoot (ScopeId "ro") readOnlyPolicy (ExclusivePath (AbsolutePath "C:\\scratch"))
    case renderWindows scope writeRequest of
      Left e -> expectationFailure (show e)
      Right plan -> do
        lpArgv plan `shouldSatisfy` contains "--policy"
        lpArgv plan `shouldSatisfy` contains "read-only"

  it "rejects danger-full-access instead of rendering it" $ do
    let scope = scopeRoot (ScopeId "d") DangerFullAccess (ExclusivePath (AbsolutePath "C:\\scratch"))
    renderWindows scope writeRequest `shouldSatisfy` isLeft

  it "passes the network policy through in wire form" $ do
    let scope = scopeRoot (ScopeId "p") proxyPolicy (ExclusivePath (AbsolutePath "C:\\scratch"))
    case renderWindows scope writeRequest of
      Left e -> expectationFailure (show e)
      Right plan -> do
        lpNetwork plan `shouldBe` NetworkProxy "http://127.0.0.1:10808"
        lpArgv plan `shouldSatisfy` contains "proxy:http://127.0.0.1:10808"

  describe "windows probe set (T4.6)" $ do
    it "covers write-inside, write-outside, secret read, junction escape and network" $ do
      map prId windowsProbes `shouldBe`
        [ "write-workspace", "write-system", "read-user-secret", "junction-escape", "network" ]

    it "only expects the workspace write to succeed under workspace-write" $ do
      [ prId p | p <- windowsProbes, prExpect p == ExpectSuccess ]
        `shouldBe` ["write-workspace"]

    it "expects every probe to fail under read-only" $ do
      [ prId p | p <- windowsReadOnlyProbes, prExpect p == ExpectSuccess ]
        `shouldBe` []

    it "reports partial enforcement so read-only is not oversold" $ do
      bcEnforcement windowsCaps `shouldSatisfy` isPartial

-- Helpers ---------------------------------------------------------------

writeRequest :: LaunchRequest
writeRequest = LaunchRequest
  { lrArgv = ["cmd.exe", "/c", "echo hi"]
  , lrCwd = AbsolutePath "C:\\ws"
  , lrEnv = []
  , lrStdin = StdinClosed
  , lrTimeoutMs = Just 5000
  , lrDenyReads = []
  , lrDenyFiles = []
  }

writeScope :: Scope
writeScope = scopeRoot (ScopeId "w")
  (WorkspaceWrite WritableRoot
    { wrRoot = AbsolutePath "C:\\ws"
    , wrScratch = ExclusivePath (AbsolutePath "C:\\scratch")
    , wrReadOnly = []
    , wrNetwork = NetworkOff
    , wrLimits = defaultResourceLimits
    })
  (ExclusivePath (AbsolutePath "C:\\scratch"))

readOnlyPolicy :: Policy
readOnlyPolicy = ReadOnly ReadOnlyPolicy
  { roReadableRoots = [AbsolutePath "C:\\ws"]
  , roNetwork = NetworkOff
  , roEnvAllow = []
  }

proxyPolicy :: Policy
proxyPolicy = WorkspaceWrite WritableRoot
  { wrRoot = AbsolutePath "C:\\ws"
  , wrScratch = ExclusivePath (AbsolutePath "C:\\scratch")
  , wrReadOnly = []
  , wrNetwork = NetworkProxy "http://127.0.0.1:10808"
  , wrLimits = defaultResourceLimits
  }

contains :: Text -> [Text] -> Bool
contains needle = any (== needle)

isPartial :: Enforcement -> Bool
isPartial (Partial _) = True
isPartial _ = False

isLeft :: Either a b -> Bool
isLeft (Left _) = True
isLeft _ = False
