{-# LANGUAGE OverloadedStrings #-}

-- | Golden tests for the BSD renderers (T5.1/T5.2): both are pure functions,
-- so the whole contract is asserted on Linux.
module SandboxBsdSpec (sandboxBsdSpec) where

import Infrastructure.Sandbox.Backend (BackendCapabilities(..))
import Infrastructure.Sandbox.Backend.FreeBSD
  ( renderFreeBSD, freeBSDCaps )
import Infrastructure.Sandbox.Backend.OpenBSD
  ( pledgePromises, renderOpenBSD, unveilEntries )
import Infrastructure.Sandbox.Plan
import Infrastructure.Sandbox.Policy
import Infrastructure.Sandbox.Scope
import Test.Hspec

sandboxBsdSpec :: Spec
sandboxBsdSpec = describe "BSD renderers (T5.1/T5.2)" $ do
  describe "freebsd (capsicum)" $ do
    it "renders the launcher one-shot invocation" $ do
      case renderFreeBSD writeScope writeRequest of
        Left e -> expectationFailure (show e)
        Right plan ->
          lpArgv plan `shouldBe`
            [ "trha-sandbox-bsd"
            , "--workspace", "/ws"
            , "--scratch", "/scratch"
            , "--policy", "workspace-write"
            , "--network", "off"
            , "--"
            , "sh", "-c", "echo hi"
            ]

    it "reports partial enforcement (capsicum is capability-, not path-based)" $ do
      bcEnforcement freeBSDCaps `shouldSatisfy` isPartial
      case renderFreeBSD writeScope writeRequest of
        Left e -> expectationFailure (show e)
        Right plan -> lpEnforcement plan `shouldSatisfy` isPartial

    it "rejects danger-full-access" $ do
      let scope = scopeRoot (ScopeId "d") DangerFullAccess (ExclusivePath (AbsolutePath "/scratch"))
      renderFreeBSD scope writeRequest `shouldSatisfy` isLeft

  describe "openbsd (pledge/unveil)" $ do
    it "promises read-only syscalls for a read-only policy" $ do
      pledgePromises readOnlyPolicy NetworkOff `shouldBe` "stdio rpath proc exec"

    it "adds wpath/cpath for workspace-write" $ do
      pledgePromises writePolicy NetworkOff `shouldBe`
        "stdio rpath wpath cpath proc exec"

    it "adds inet only when the network is open" $ do
      pledgePromises writePolicy (NetworkAllow ["example.com"]) `shouldBe`
        "stdio rpath wpath cpath proc exec inet"
      pledgePromises writePolicy (NetworkProxy "http://127.0.0.1:10808") `shouldBe`
        "stdio rpath wpath cpath proc exec inet"

    it "unveils the workspace read-write only for workspace-write" $ do
      unveilEntries writePolicy "/ws" "/scratch" `shouldBe`
        ["/ws:rw", "/scratch:rw", "/etc:r", "/usr:r", "/bin:r", "/sbin:r"]
      unveilEntries readOnlyPolicy "/ws" "/scratch" `shouldBe`
        ["/ws:r", "/scratch:rw", "/etc:r", "/usr:r", "/bin:r", "/sbin:r"]

    it "renders pledge and unveil into the launcher argv" $ do
      case renderOpenBSD writeScope writeRequest of
        Left e -> expectationFailure (show e)
        Right plan -> do
          lpArgv plan `shouldBe`
            [ "trha-sandbox-obsd"
            , "--pledge", "stdio rpath wpath cpath proc exec"
            , "--unveil", "/ws:rw"
            , "--unveil", "/scratch:rw"
            , "--unveil", "/etc:r"
            , "--unveil", "/usr:r"
            , "--unveil", "/bin:r"
            , "--unveil", "/sbin:r"
            , "--"
            , "sh", "-c", "echo hi"
            ]

    it "rejects danger-full-access" $ do
      let scope = scopeRoot (ScopeId "d") DangerFullAccess (ExclusivePath (AbsolutePath "/scratch"))
      renderOpenBSD scope writeRequest `shouldSatisfy` isLeft

-- Helpers ---------------------------------------------------------------

writeRequest :: LaunchRequest
writeRequest = LaunchRequest
  { lrArgv = ["sh", "-c", "echo hi"]
  , lrCwd = AbsolutePath "/ws"
  , lrEnv = []
  , lrStdin = StdinClosed
  , lrTimeoutMs = Just 5000
  }

writePolicy :: Policy
writePolicy = WorkspaceWrite WritableRoot
  { wrRoot = AbsolutePath "/ws"
  , wrScratch = ExclusivePath (AbsolutePath "/scratch")
  , wrReadOnly = []
  , wrNetwork = NetworkOff
  , wrLimits = defaultResourceLimits
  }

readOnlyPolicy :: Policy
readOnlyPolicy = ReadOnly ReadOnlyPolicy
  { roReadableRoots = [AbsolutePath "/ws"]
  , roNetwork = NetworkOff
  , roEnvAllow = []
  }

writeScope :: Scope
writeScope = scopeRoot (ScopeId "w") writePolicy (ExclusivePath (AbsolutePath "/scratch"))

isPartial :: Enforcement -> Bool
isPartial (Partial _) = True
isPartial _ = False

isLeft :: Either a b -> Bool
isLeft (Left _) = True
isLeft _ = False
