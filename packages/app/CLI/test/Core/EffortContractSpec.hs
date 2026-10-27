{-# LANGUAGE OverloadedStrings #-}

module Core.EffortContractSpec (spec) where

import Test.Hspec
import Core.EffortContract

spec :: Spec
spec = do
  describe "vendorOf" $ do
    it "recognises the documented hosts" $ do
      vendorOf "https://open.bigmodel.cn/api/paas/v4" `shouldBe` "zhipu"
      vendorOf "https://api.z.ai/api/paas/v4" `shouldBe` "zhipu"
      vendorOf "https://api.deepseek.com/v1" `shouldBe` "deepseek"
      vendorOf "https://api.moonshot.cn/v1" `shouldBe` "kimi"
      vendorOf "https://example.com/v1" `shouldBe` ""
  describe "contractFor" $ do
    it "uses GLM-5.2's seven-level ladder with a max default" $ do
      let c = contractFor "https://open.bigmodel.cn/api/paas/v4" "openai" "GLM-5.2"
      ecLevels c `shouldBe` ["none", "minimal", "low", "medium", "high", "xhigh", "max"]
      ecDefault c `shouldBe` "max"
      ecThinkingOff c `shouldBe` ["none", "minimal"]
      ecForced c `shouldBe` False
    it "marks GLM-5.3 as always-thinking with three levels" $ do
      let c = contractFor "https://api.z.ai/api/paas/v4" "openai" "glm-5.3"
      ecLevels c `shouldBe` ["low", "high", "max"]
      ecForced c `shouldBe` True
    it "falls back to the generic ladder for unknown vendors" $
      ecLevels (contractFor "https://example.com/v1" "openai" "x") `shouldBe`
        ["auto", "minimal", "low", "medium", "high"]
  describe "levelsFor" $ do
    it "prefers a probed ladder" $
      levelsFor ["low", "high"] "https://example.com" "openai" "x"
        `shouldBe` ["auto", "low", "high"]
    it "uses the contract when nothing was probed" $
      levelsFor [] "https://api.openai.com/v1" "openai" "gpt-4o"
        `shouldBe` ["minimal", "low", "medium", "high"]
