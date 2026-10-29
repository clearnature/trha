{-# LANGUAGE OverloadedStrings #-}

-- | P0 judgement tests for the sandbox seam (docs/plans/sandbox-architecture.md §6.1/§6.2).
module SandboxSpec (sandboxSpec) where

import Data.Maybe (isJust)
import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Lazy as BL
import qualified Data.Set as Set
import qualified Data.Text as T
import Infrastructure.Sandbox
import Infrastructure.Sandbox.Backend
  ( Backend(..), BackendCapabilities(..), planWith )
import qualified Infrastructure.Sandbox.Backend.Linux as Linux
import qualified Infrastructure.Sandbox.Backend.Mac as Mac
import Infrastructure.Sandbox.Config
import Infrastructure.Sandbox.Probe
import Infrastructure.Sandbox.Protocol
import Test.Hspec
import Test.QuickCheck

-- Helpers ---------------------------------------------------------------

absP :: FilePath -> AbsolutePath
absP = AbsolutePath

ro :: [FilePath] -> NetworkPolicy -> ReadOnlyPolicy
ro roots net = ReadOnlyPolicy (map absP roots) net ["PATH"]

wr :: FilePath -> FilePath -> [FilePath] -> NetworkPolicy -> ResourceLimits -> WritableRoot
wr root scratch extra net limits = WritableRoot
  { wrRoot = absP root
  , wrScratch = ExclusivePath (absP scratch)
  , wrReadOnly = map absP extra
  , wrNetwork = net
  , wrLimits = limits
  }

scopeFor :: Policy -> Scope
scopeFor policy = scopeRoot (ScopeId "s1") policy (ExclusivePath (absP "/ws/scratch"))

mockBackend :: Backend
mockBackend = Backend
  { backendId = BackendId "mock"
  , backendProbe = pure (Right capsFull)
  , backendRender = \_ _ -> Right LaunchPlan
      { lpBackend = BackendId "mock"
      , lpArgv = []
      , lpEnforcement = Full
      , lpMounts = []
      , lpNetwork = NetworkOff
      , lpLimits = defaultResourceLimits
      }
  }

capsFull :: BackendCapabilities
capsFull = BackendCapabilities
  { bcBackend = BackendId "mock"
  , bcPlatform = Linux
  , bcCapabilities = Set.fromList
      [CapFsRead, CapFsWrite, CapNet, CapPid, CapSyscall, CapResource, CapCred]
  , bcEnforcement = Full
  , bcNotes = []
  }

capsMissing :: BackendCapabilities
capsMissing = capsFull
  { bcCapabilities = Set.fromList [CapFsRead, CapCred]
  , bcEnforcement = Partial (PartialReason (Set.fromList [CapFsWrite]) "write confinement unavailable")
  }

request :: LaunchRequest
request = LaunchRequest
  { lrArgv = ["bash", "-lc", "true"]
  , lrCwd = absP "/ws"
  , lrEnv = []
  , lrStdin = StdinClosed
  , lrTimeoutMs = Nothing
  }

-- Spec ------------------------------------------------------------------

sandboxSpec :: Spec
sandboxSpec = describe "Infrastructure.Sandbox" $ do
  describe "narrow (P0: widening is rejected)" $ do
    it "rejects read-only -> danger-full-access" $
      narrow (ReadOnly (ro ["/ws"] NetworkOff)) DangerFullAccess
        `shouldBe` Nothing

    it "rejects danger-full-access -> anything without an explicit root" $
      narrow DangerFullAccess (ReadOnly (ro ["/ws"] NetworkOff))
        `shouldBe` Nothing

    it "rejects a writable root outside the parent" $
      narrow
        (WorkspaceWrite (wr "/ws" "/ws/scratch" [] NetworkOff defaultResourceLimits))
        (WorkspaceWrite (wr "/other" "/other/scratch" [] NetworkOff defaultResourceLimits))
        `shouldBe` Nothing

    it "rejects a scratch directory outside its own root" $
      narrow
        (WorkspaceWrite (wr "/ws" "/ws/scratch" [] NetworkOff defaultResourceLimits))
        (WorkspaceWrite (wr "/ws" "/elsewhere" [] NetworkOff defaultResourceLimits))
        `shouldBe` Nothing

    it "rejects network widening" $
      narrow
        (ReadOnly (ro [] NetworkOff))
        (ReadOnly (ro [] (NetworkAllow ["example.com"])))
        `shouldBe` Nothing

    it "rejects resource-limit widening" $
      narrow
        (WorkspaceWrite (wr "/ws" "/ws/scratch" [] NetworkOff
          defaultResourceLimits { rlPids = 64 }))
        (WorkspaceWrite (wr "/ws" "/ws/scratch" [] NetworkOff
          defaultResourceLimits { rlPids = 128 }))
        `shouldBe` Nothing

    it "accepts a narrower read-only policy" $
      narrow
        (ReadOnly (ro ["/usr", "/ws"] (NetworkAllow ["a", "b"])))
        (ReadOnly (ro ["/usr"] (NetworkAllow ["a"])))
        `shouldSatisfy` isJust

    it "accepts a workspace-write policy narrowed from read-only" $
      narrow
        (WorkspaceWrite (wr "/ws" "/ws/scratch" ["/usr"] NetworkOff defaultResourceLimits))
        (ReadOnly (ro ["/ws", "/usr"] NetworkOff))
        `shouldSatisfy` isJust

    it "property: a narrowed writable root stays under its parent" $
      property $ \(NonEmpty parts) ->
        let childRoot = "/ws/" ++ concatMap (++ "/") parts
         in case narrow
              (WorkspaceWrite (wr "/ws" "/ws/scratch" [] NetworkOff defaultResourceLimits))
              (WorkspaceWrite (wr childRoot (childRoot ++ "/scratch") [] NetworkOff defaultResourceLimits)) of
              Nothing -> True
              Just _ -> isUnder (absP "/ws") (absP childRoot)

  describe "Protocol v1" $ do
    it "round-trips hello" $ do
      let frame = Hello "root/a" (Just "root") "workspace-write" "process"
      decodeFrame (BL.toStrict (encodeFrame frame)) `shouldBe` Right frame

    it "round-trips exec" $ do
      let frame = Exec "c1" ["bash", "-lc", "true"] "/ws" [("PATH", "/usr/bin")] Nothing (Just 1000)
      decodeFrame (BL.toStrict (encodeFrame frame)) `shouldBe` Right frame

    it "round-trips exit and deny" $ do
      let exitFrame = Exit "c1" 0 Nothing
          denyFrame = Deny "c2" "fs-write" "/etc/passwd"
      decodeFrame (BL.toStrict (encodeFrame exitFrame)) `shouldBe` Right exitFrame
      decodeFrame (BL.toStrict (encodeFrame denyFrame)) `shouldBe` Right denyFrame

    it "rejects an unknown op" $ do
      decodeFrame "{\"v\":1,\"op\":\"teleport\"}"
        `shouldSatisfy` isMalformed

    it "rejects a frame above the size cap" $ do
      let huge = BL.toStrict (BL.replicate (fromIntegral (maxFrameBytes + 1)) 32)
      decodeFrame huge `shouldSatisfy` isTooLarge

    it "rejects a version mismatch" $ do
      decodeFrame "{\"v\":99,\"op\":\"shutdown\"}"
        `shouldSatisfy` isMalformed

  describe "Config v1" $ do
    it "parses defaults, network and scopes" $ do
      let value = Aeson.object
            [ "version" Aeson..= (1 :: Int)
            , "defaults" Aeson..= Aeson.object
                [ "policy" Aeson..= ("read-only" :: T.Text)
                , "network" Aeson..= ("allow:example.com, api.example.com" :: T.Text)
                , "limits" Aeson..= Aeson.object ["pids" Aeson..= (32 :: Int)]
                ]
            , "scopes" Aeson..= Aeson.object
                [ "subagent" Aeson..= Aeson.object
                    ["policy" Aeson..= ("read-only" :: T.Text)] ]
            ]
      case parseSandboxConfig value of
        Left e -> expectationFailure (T.unpack e)
        Right cfg -> do
          dcPolicy (scDefaults cfg) `shouldBe` "read-only"
          dcNetwork (scDefaults cfg) `shouldBe` NetAllow ["example.com", "api.example.com"]
          rlPids (dcLimits (scDefaults cfg)) `shouldBe` 32
          map fst (scScopes cfg) `shouldBe` ["subagent"]

    it "rejects unknown top-level keys" $ do
      let value = Aeson.object ["version" Aeson..= (1 :: Int), "bogus" Aeson..= (1 :: Int)]
      parseSandboxConfig value `shouldSatisfy` isConfigError

    it "rejects an unsupported version" $ do
      let value = Aeson.object ["version" Aeson..= (2 :: Int)]
      parseSandboxConfig value `shouldSatisfy` isConfigError

  describe "macOS renderer (T3.1)" $ do
    it "renders a seatbelt profile with write deny and subpath allow" $ do
      let scope = scopeRoot (ScopeId "s")
            (WorkspaceWrite (wr "/ws" "/state/s" [] NetworkOff defaultResourceLimits))
            (ExclusivePath (absP "/state/s"))
      case Mac.renderMac scope request of
        Left e -> expectationFailure (show e)
        Right plan -> do
          lpArgv plan `shouldSatisfy` elem "sandbox-exec"
          lpArgv plan `shouldSatisfy` elem "-p"
          let profile = case lpArgv plan of
                ("sandbox-exec" : "-p" : p : _) -> p
                _ -> ""
          profile `shouldSatisfy` T.isInfixOf "(deny file-write*)"
          profile `shouldSatisfy` T.isInfixOf "(subpath \"/ws\")"
          profile `shouldSatisfy` T.isInfixOf "(deny network*)"
          -- SBPL is first-match-wins: the writable allow must precede the
          -- blanket deny, otherwise every write (including /ws) is rejected.
          let at s = let (before, after) = T.breakOn s profile
                     in if T.null after then Nothing else Just (T.length before)
          case (at "(allow file-write*", at "(deny file-write*)") of
            (Just a, Just d) -> a `shouldSatisfy` (< d)
            _ -> expectationFailure "profile must contain both write rules"

    it "allows network when the policy does" $ do
      let scope = scopeRoot (ScopeId "s")
            (WorkspaceWrite (wr "/ws" "/state/s" [] (NetworkAllow ["example.com"]) defaultResourceLimits))
            (ExclusivePath (absP "/state/s"))
      case Mac.renderMac scope request of
        Left e -> expectationFailure (show e)
        Right plan -> do
          let profile = case lpArgv plan of
                ("sandbox-exec" : "-p" : p : _) -> p
                _ -> ""
          profile `shouldSatisfy` T.isInfixOf "(allow network*)"

    it "rejects danger-full-access" $ do
      let scope = scopeRoot (ScopeId "s") DangerFullAccess (ExclusivePath (absP "/state/s"))
      Mac.renderMac scope request `shouldSatisfy` isLeft

  describe "probes (T1.5)" $ do
    it "has one positive and several negative boundaries" $ do
      map prId defaultProbes
        `shouldBe` ["write-workspace", "write-etc", "read-ssh", "network"]
      prExpect (head defaultProbes) `shouldBe` ExpectSuccess
      map prExpect (drop 1 defaultProbes) `shouldBe` replicate 3 ExpectFailure

  describe "Linux renderer (T1.1/T1.2)" $ do
    it "renders a workspace-write plan with namespaces and cleanup" $ do
      let scope = scopeRoot (ScopeId "s")
            (WorkspaceWrite (wr "/ws" "/state/s" [] NetworkOff defaultResourceLimits))
            (ExclusivePath (absP "/state/s"))
      case Linux.renderLinux scope request of
        Left e -> expectationFailure (show e)
        Right plan -> do
          lpBackend plan `shouldBe` BackendId "linux-bwrap"
          lpArgv plan `shouldSatisfy` notElem "prlimit"
          lpArgv plan `shouldSatisfy` elem "--unshare-all"
          lpArgv plan `shouldSatisfy` elem "--bind"
          lpArgv plan `shouldSatisfy` elem "--new-session"
          lpArgv plan `shouldSatisfy` elem "--die-with-parent"
          lpArgv plan `shouldSatisfy` elem "/ws"

    it "caps memory with prlimit --as when configured" $ do
      let scope = scopeRoot (ScopeId "s")
            (WorkspaceWrite (wr "/ws" "/state/s" []
              NetworkOff (defaultResourceLimits { rlMemoryMiB = 256 })))
            (ExclusivePath (absP "/state/s"))
      case Linux.renderLinux scope request of
        Left e -> expectationFailure (show e)
        Right plan -> do
          lpArgv plan `shouldSatisfy` elem "prlimit"
          lpArgv plan `shouldSatisfy` elem "--as=268435456"
          lpArgv plan `shouldSatisfy` notElem "--nproc=512"

    it "does not grant writable binds for read-only policies" $ do
      let scope = scopeRoot (ScopeId "s") (ReadOnly (ro ["/ws"] NetworkOff))
            (ExclusivePath (absP "/state/s"))
      case Linux.renderLinux scope request of
        Left e -> expectationFailure (show e)
        Right plan -> do
          lpArgv plan `shouldSatisfy` notElem "--bind"
          lpArgv plan `shouldSatisfy` notElem "--share-net"

    it "adds proxy env for proxy policies" $ do
      let scope = scopeRoot (ScopeId "s")
            (WorkspaceWrite (wr "/ws" "/state/s" []
              (NetworkProxy "http://127.0.0.1:10808") defaultResourceLimits))
            (ExclusivePath (absP "/state/s"))
      case Linux.renderLinux scope request of
        Left e -> expectationFailure (show e)
        Right plan -> do
          lpArgv plan `shouldSatisfy` elem "--share-net"
          lpArgv plan `shouldSatisfy` elem "HTTP_PROXY"
          lpArgv plan `shouldSatisfy` elem "http://127.0.0.1:10808"

    it "adds --share-net only when networking is allowed" $ do
      let scope = scopeRoot (ScopeId "s")
            (ReadOnly (ro ["/ws"] (NetworkAllow ["example.com"])))
            (ExclusivePath (absP "/state/s"))
      case Linux.renderLinux scope request of
        Left e -> expectationFailure (show e)
        Right plan -> lpArgv plan `shouldSatisfy` elem "--share-net"

    it "refuses danger-full-access" $ do
      let scope = scopeRoot (ScopeId "s") DangerFullAccess
            (ExclusivePath (absP "/state/s"))
      Linux.renderLinux scope request `shouldSatisfy` isPolicyRejected

    it "drops credential environment variables" $ do
      Linux.sanitizeEnv
        [ ("PATH", "/bin")
        , ("SSH_AUTH_SOCK", "/tmp/agent")
        , ("AWS_SECRET_ACCESS_KEY", "secret")
        , ("LANG", "C.UTF-8")
        ]
        `shouldBe` [("PATH", "/bin"), ("LANG", "C.UTF-8")]

    it "probes bwrap without inventing a backend" $ do
      probed <- Linux.probeLinux
      case probed of
        Right caps -> bcBackend caps `shouldBe` BackendId "linux-bwrap"
        Left (SandboxUnavailable _ _) -> pure ()
        Left other -> expectationFailure ("unexpected probe error: " ++ show other)

  describe "scope inheritance" $ do
    it "rejects a child that widens its parent" $ do
      let parent = scopeRoot (ScopeId "p") (ReadOnly (ro ["/ws"] NetworkOff))
            (ExclusivePath (absP "/state/p"))
      scopeChild parent (ScopeId "c") (ReadOnly (ro ["/etc"] NetworkOff))
        (ExclusivePath (absP "/state/c"))
        `shouldSatisfy` isLeft

    it "accepts a narrower child" $ do
      let parent = scopeRoot (ScopeId "p") (ReadOnly (ro ["/ws", "/usr"] NetworkOff))
            (ExclusivePath (absP "/state/p"))
      case scopeChild parent (ScopeId "c") (ReadOnly (ro ["/ws"] NetworkOff))
            (ExclusivePath (absP "/state/c")) of
        Left e -> expectationFailure (show e)
        Right child -> scId child `shouldBe` ScopeId "c"

  describe "planWith (P0: fail-closed)" $ do
    it "refuses when the backend reports Enforcement None" $ do
      let caps = capsFull { bcEnforcement = None "platform has no OS sandbox" }
      case planWith mockBackend caps (scopeFor (ReadOnly (ro ["/ws"] NetworkOff))) request of
        Left (SandboxUnavailable _ _) -> pure ()
        other -> expectationFailure ("expected SandboxUnavailable, got " ++ show other)

    it "refuses when a required capability is missing" $ do
      let scope = scopeFor (WorkspaceWrite (wr "/ws" "/ws/scratch" [] NetworkOff defaultResourceLimits))
      case planWith mockBackend capsMissing scope request of
        Left (SandboxUnavailable _ msg) ->
          msg `shouldSatisfy` T.isInfixOf "CapFsWrite"
        other -> expectationFailure ("expected SandboxUnavailable, got " ++ show other)

    it "renders when every capability is available" $ do
      let scope = scopeFor (ReadOnly (ro ["/ws"] NetworkOff))
      case planWith mockBackend capsFull scope request of
        Left e -> expectationFailure (show e)
        Right plan -> lpBackend plan `shouldBe` BackendId "mock"

  where
    isLeft (Left _) = True
    isLeft _ = False
    isMalformed (Left MalformedFrame{}) = True
    isMalformed _ = False
    isTooLarge (Left FrameTooLarge{}) = True
    isTooLarge _ = False
    isConfigError (Left _) = True
    isConfigError _ = False
    isPolicyRejected (Left (PolicyRejected _)) = True
    isPolicyRejected _ = False
