{-# LANGUAGE OverloadedStrings #-}

-- | Landlock probe (T1.3): the capability is reported, not enforced, so what
-- these tests pin down is (a) the ABI mapping and (b) that the state is
-- visible in the Linux backend's notes.
module SandboxLandlockSpec (sandboxLandlockSpec) where

import qualified Data.Text as T
import Infrastructure.Sandbox (BackendCapabilities(..))
import qualified Infrastructure.Sandbox.Backend.Linux as Linux
import Infrastructure.Sandbox.Landlock
import Test.Hspec

sandboxLandlockSpec :: Spec
sandboxLandlockSpec = describe "landlock probe (T1.3)" $ do
  it "maps kernel releases to the ABI number" $ do
    abiForRelease (5, 12) `shouldBe` Nothing
    abiForRelease (5, 13) `shouldBe` Just 1
    abiForRelease (6, 1) `shouldBe` Just 1
    abiForRelease (6, 2) `shouldBe` Just 2
    abiForRelease (6, 8) `shouldBe` Just 3
    abiForRelease (6, 10) `shouldBe` Just 4
    abiForRelease (6, 12) `shouldBe` Just 5
    abiForRelease (6, 99) `shouldBe` Just 5

  it "reports the state without throwing, and says which it is" $ do
    ll <- detectLandlock
    llNote ll `shouldSatisfy` T.isInfixOf "landlock:"
    if llEnabled ll
      then llNote ll `shouldSatisfy` T.isInfixOf "enabled"
      else llNote ll `shouldSatisfy` T.isInfixOf "not enabled"

  it "only carries an ABI hint when landlock is enabled" $ do
    ll <- detectLandlock
    if llEnabled ll
      then llAbi ll `shouldSatisfy` maybe True (> 0)
      else llAbi ll `shouldBe` Nothing

  it "never claims enforcement, because rules need a launcher" $ do
    ll <- detectLandlock
    if llEnabled ll
      then do
        llNote ll `shouldSatisfy` T.isInfixOf "need a launcher"
        llNote ll `shouldSatisfy` T.isInfixOf "not enforced yet"
      else llNote ll `shouldSatisfy` T.isInfixOf "bwrap still provides"

  it "surfaces the landlock state in the linux probe notes" $ do
    caps <- Linux.probeLinux
    case caps of
      Left e -> pendingWith ("bwrap unavailable: " ++ show e)
      Right c -> bcNotes c `shouldSatisfy` any (T.isInfixOf "landlock:")
