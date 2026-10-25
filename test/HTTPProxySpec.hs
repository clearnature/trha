{-# LANGUAGE OverloadedStrings #-}

-- | Pure core of the kernel proxy policy (see "Core.HTTPProxy").
--
-- Contract: loopback targets are always contacted directly — a machine-wide
-- @http_proxy@ must not intercept local model gateways — and remote targets
-- follow @TRHA_PROXY@ (unset = environment default, @none@ = direct, else a
-- forced @http://host:port@).
module HTTPProxySpec (spec) where

import Test.Hspec

import Core.HTTPProxy

spec :: Spec
spec = describe "Core.HTTPProxy" $ do
  describe "isLoopbackHost" $ do
    it "classifies loopback names and 127/8 addresses" $ do
      isLoopbackHost "127.0.0.1" `shouldBe` True
      isLoopbackHost "127.9.9.9" `shouldBe` True
      isLoopbackHost "localhost" `shouldBe` True
      isLoopbackHost "LOCALHOST" `shouldBe` True
      isLoopbackHost "::1" `shouldBe` True
      isLoopbackHost "  127.0.0.1  " `shouldBe` True

    it "classifies remote API hosts as non-loopback" $ do
      isLoopbackHost "api.deepseek.com" `shouldBe` False
      isLoopbackHost "api.openai.com" `shouldBe` False

  describe "parseProxySpec" $ do
    it "parses with and without scheme, rejects garbage" $ do
      parseProxySpec "http://127.0.0.1:10808" `shouldBe` Just ("127.0.0.1", 10808)
      parseProxySpec "proxy.lan:3128" `shouldBe` Just ("proxy.lan", 3128)
      parseProxySpec "garbage" `shouldBe` Nothing
      parseProxySpec "host:port" `shouldBe` Nothing

  describe "resolveProxyChoice" $ do
    it "keeps loopback direct whatever the spec says" $ do
      resolveProxyChoice True (Just "http://proxy:10808") `shouldBe` ProxyDirect
      resolveProxyChoice True Nothing `shouldBe` ProxyDirect

    it "follows TRHA_PROXY for remote targets" $ do
      resolveProxyChoice False Nothing `shouldBe` ProxyFromEnv
      resolveProxyChoice False (Just "none") `shouldBe` ProxyDirect
      resolveProxyChoice False (Just "http://p.local:10808")
        `shouldBe` ProxyForced "p.local" 10808
      -- an unparsable spec degrades to the environment default, not to direct
      resolveProxyChoice False (Just "garbage") `shouldBe` ProxyFromEnv
