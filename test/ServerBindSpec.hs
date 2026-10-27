-- | The kernel API must never listen on a routable address.
--
-- Regression (2026-10-27): @startServer@ used Warp's bare @run@, which binds
-- @*4@ (0.0.0.0).  The kernel has no authentication of its own — the Bearer
-- token lives on the scheduler side — so a routable bind let any peer on the
-- network read sessions and spend the provider budget.  The documents said
-- "127.0.0.1 by default" long before the code did.
module ServerBindSpec (serverBindSpec) where

import Test.Hspec
import Data.List (isInfixOf)
import Network.Wai.Handler.Warp (getHost, getPort)
import API.Server (kernelBindAddress, kernelSettings)

serverBindSpec :: Spec
serverBindSpec = describe "API.Server kernel bind (loopback only)" $ do
  it "names 127.0.0.1 as the bind address" $
    kernelBindAddress `shouldBe` "127.0.0.1"

  -- Warp's HostPreference has no Eq/readable accessor; `show` renders the
  -- wrapped address, and the default (HostAny / "*4") contains no 127.0.0.1.
  it "builds Warp settings bound to loopback" $
    show (getHost (kernelSettings 19433)) `shouldSatisfy` ("127.0.0.1" `isInfixOf`)

  it "keeps the requested port" $ do
    getPort (kernelSettings 19433) `shouldBe` 19433
    getPort (kernelSettings 0) `shouldBe` 0
