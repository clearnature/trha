{-# LANGUAGE OverloadedStrings #-}

-- | macOS Seatbelt integration probes (T3.3).  Skipped on non-Darwin hosts;
-- the GitHub macOS runner executes the real set (T3.5).
module SandboxMacSpec (sandboxMacSpec) where

import Control.Exception (SomeException, try)
import Infrastructure.Sandbox
import qualified Infrastructure.Sandbox.Backend.Mac as Mac
import Infrastructure.Sandbox.Probe
import System.Directory
  ( createDirectoryIfMissing, getHomeDirectory, removeDirectoryRecursive )
import System.FilePath ((</>))
import System.Info (os)
import Test.Hspec

sandboxMacSpec :: Spec
sandboxMacSpec = describe "macOS sandbox integration (T3.3)" $ do
  it "enforces the seatbelt profile with the probe set" $ do
    if os /= "darwin"
      then pendingWith "macOS only"
      else do
        caps <- Mac.probeMac
        case caps of
          Left (SandboxUnavailable _ msg) ->
            pendingWith ("sandbox-exec unavailable: " ++ show msg)
          Left e -> expectationFailure (show e)
          Right c -> do
            home <- getHomeDirectory
            let ws = home </> ".trha-sandbox-mac"
            createDirectoryIfMissing True ws
            results <- runProbesWith Mac.backend c (probeScope ws) macProbes
            _ <- try (removeDirectoryRecursive ws) :: IO (Either SomeException ())
            map probeName results
              `shouldBe` ["write-workspace", "write-etc", "read-ssh", "network"]
            map probeOk results `shouldBe` [True, True, True, True]

probeScope :: FilePath -> Scope
probeScope ws = scopeRoot (ScopeId "mac") policy (ExclusivePath (AbsolutePath ws))
  where
    policy = WorkspaceWrite WritableRoot
      { wrRoot = AbsolutePath ws
      , wrScratch = ExclusivePath (AbsolutePath ws)
      , wrReadOnly = []
      , wrNetwork = NetworkOff
      , wrLimits = defaultResourceLimits
      }
