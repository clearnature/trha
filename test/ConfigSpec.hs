{-# LANGUAGE OverloadedStrings #-}

-- | sandbox.yaml write side (T2.7/T1.8 wiring): enabled/scratch round-trip.
module ConfigSpec (configSpec, sandboxGuestSpec) where

import Infrastructure.Sandbox.Config
import Infrastructure.Sandbox.Policy (NetworkPolicy(..))
import Data.List (isSuffixOf)
import qualified Data.Text as T
import System.Directory
  ( doesFileExist, getHomeDirectory, getTemporaryDirectory, removeFile )
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

  -- §5.7.5 read.deny wiring (2026-10-30): an explicit list replaces the
  -- shipped masks; a written-back Nothing must survive as `null`, not fail
  -- the strict parser.
  it "round-trips an explicit denyReadDirs override and keeps null as defaults" $ do
    path <- tempFile "denyreads"
    let base = scDefaults defaultSandboxConfig
        overridden = defaultSandboxConfig
          { scDefaults = base { dcDenyReadDirs = Just [".ssh", ".config/gh"] } }
    saveSandboxConfig path overridden
    loadedO <- loadSandboxConfig path
    case loadedO of
      Left e -> expectationFailure (show e)
      Right cfg' -> dcDenyReadDirs (scDefaults cfg') `shouldBe` Just [".ssh", ".config/gh"]
    -- An empty explicit list is *not* the same as absent: it un-masks.
    saveSandboxConfig path (defaultSandboxConfig
      { scDefaults = base { dcDenyReadDirs = Just [] } })
    loadedE <- loadSandboxConfig path
    case loadedE of
      Left e -> expectationFailure (show e)
      Right cfg' -> dcDenyReadDirs (scDefaults cfg') `shouldBe` Just []
    -- Absent/null round-trips back to Nothing (= shipped defaults in force).
    saveSandboxConfig path defaultSandboxConfig
    loadedN <- loadSandboxConfig path
    case loadedN of
      Left e -> expectationFailure (T.unpack ("null must parse as absent: " <> e))
      Right cfg' -> dcDenyReadDirs (scDefaults cfg') `shouldBe` Nothing
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
  it "treats a short uid_map range as a guest" $ do
    -- Measured: host maps everything, bwrap's --unshare-user maps 1 uid.
    guestByUidMap "         0          0 4294967295\n" `shouldBe` False
    guestByUidMap "      1000          0          1\n" `shouldBe` True
    guestByUidMap "" `shouldBe` False

  -- Deliberately environment-agnostic: this suite also runs *inside* the
  -- sandbox, where a host-only constant would fail for the wrong reason.
  it "agrees with the signals it can actually read" $ do
    home <- getHomeDirectory
    guestEnv <- lookupEnv "TRHA_SANDBOX_GUEST"
    uidMap <- readFile "/proc/self/uid_map"
    guest <- insideSandbox
    let inScratch = "sandbox-scratch" `isSuffixOf` home
        expected = guestEnv == Just "1" || inScratch || guestByUidMap (T.pack uidMap)
    guest `shouldBe` expected

  it "detects a guest by HOME ending in sandbox-scratch" $ do
    old <- lookupEnv "HOME"
    setEnv "HOME" "/tmp/trha-probe/sandbox-scratch"
    guest <- insideSandbox
    case old of
      Just h -> setEnv "HOME" h
      Nothing -> unsetEnv "HOME"
    guest `shouldBe` True
