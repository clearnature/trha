{-# LANGUAGE OverloadedStrings #-}

-- | sandbox.yaml write side (T2.7/T1.8 wiring): enabled/scratch round-trip.
module ConfigSpec (configSpec, sandboxGuestSpec) where

import Infrastructure.Sandbox.Config
import Infrastructure.Sandbox.Policy (NetworkPolicy(..))
import System.Directory (doesFileExist, getTemporaryDirectory, removeFile)
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.FilePath ((</>))
import Test.Hspec

configSpec :: Spec
configSpec = describe "sandbox config (T1.8 wiring)" $ do
  it "round-trips enabled, policy, network and scratch" $ do
    path <- tempFile "roundtrip"
    let base = scDefaults defaultSandboxConfig
        cfg = defaultSandboxConfig
          { scEnabled = True
          , scDefaults = base
              { dcPolicy = "read-only"
              , dcNetwork = NetAllow ["example.com"]
              , dcScratch = "/tmp/trha-scratch"
              }
          }
    saveSandboxConfig path cfg
    loaded <- loadSandboxConfig path
    case loaded of
      Left e -> expectationFailure (show e)
      Right cfg' -> do
        scEnabled cfg' `shouldBe` True
        dcPolicy (scDefaults cfg') `shouldBe` "read-only"
        dcNetwork (scDefaults cfg') `shouldBe` NetAllow ["example.com"]
        dcScratch (scDefaults cfg') `shouldBe` "/tmp/trha-scratch"
    cleanup path

  it "defaults enabled to off when the key is absent" $ do
    path <- tempFile "defaults"
    saveSandboxConfig path defaultSandboxConfig
    loaded <- loadSandboxConfig path
    case loaded of
      Left e -> expectationFailure (show e)
      Right cfg' -> scEnabled cfg' `shouldBe` False
    cleanup path

tempFile :: String -> IO FilePath
tempFile tag = do
  tmp <- getTemporaryDirectory
  let path = tmp </> ("trha-sandbox-config-" <> tag <> ".yaml")
  cleanup path
  pure path

cleanup :: FilePath -> IO ()
cleanup path = do
  exists <- doesFileExist path
  if exists then removeFile path else pure ()

-- | Fail-open guard (T1.2): inside the sandbox HOME is the scratch dir, so the
-- host config file is invisible. Inferring "disabled" from that absence is the
-- trap this pins down.
sandboxGuestSpec :: Spec
sandboxGuestSpec = describe "insideSandbox (fail-open guard)" $ do
  it "is False on the host (PID 1 is not bwrap, HOME is not scratch)" $ do
    guest <- insideSandbox
    guest `shouldBe` False

  it "detects a guest by HOME ending in sandbox-scratch" $ do
    old <- lookupEnv "HOME"
    setEnv "HOME" "/tmp/trha-probe/sandbox-scratch"
    guest <- insideSandbox
    case old of
      Just h -> setEnv "HOME" h
      Nothing -> unsetEnv "HOME"
    guest `shouldBe` True
