{-# LANGUAGE OverloadedStrings #-}

module UI.StatusInfoSpec (spec) where

import Test.Hspec
import UI.StatusInfo
import Core.Types (CLIConfig(..), defaultCLIConfig)
import qualified Data.Text as T

spec :: Spec
spec = do
  describe "versionLine / runtimeLine / baseUrlLine" $ do
    it "reports the product name and version" $ do
      versionLine `shouldBe` "trha 0.1.0"
    it "reports the compiler" $ do
      runtimeLine `shouldSatisfy` T.isPrefixOf "ghc"
    it "builds the base URL from the config" $ do
      baseUrlLine defaultCLIConfig `shouldBe` "http://localhost:3456"

  describe "parsePages" $ do
    it "parses the resident pages from a statm line" $ do
      parsePages "1024 512 100 1 0 0 0" `shouldBe` Just 512
    it "returns Nothing for malformed input" $ do
      parsePages "" `shouldBe` Nothing
      parsePages "onlyone" `shouldBe` Nothing

  describe "authLine" $ do
    it "flags the well-known dev default" $ do
      authLine defaultCLIConfig `shouldBe` "dev-token (default)"
    it "masks custom tokens" $ do
      let cfg = defaultCLIConfig { configToken = "sk-abcdef1234" }
      authLine cfg `shouldSatisfy` T.isInfixOf "****"
    it "reports none when the token is empty" $ do
      let cfg = defaultCLIConfig { configToken = "" }
      authLine cfg `shouldBe` "none"
