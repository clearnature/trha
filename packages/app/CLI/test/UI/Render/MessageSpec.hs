{-# LANGUAGE OverloadedStrings #-}

module UI.Render.MessageSpec (spec) where

import Core.Types (Usage(..), mkUsage)
import Test.Hspec
import UI.Render.Message

spec :: Spec
spec = do
  describe "classifyError" $ do
    it "recognises rate limits" $ do
      classifyError "Error: 429 Too Many Requests" `shouldBe` ErrRateLimit
      classifyError "provider says: rate limit exceeded" `shouldBe` ErrRateLimit
      classifyError "quota exhausted" `shouldBe` ErrRateLimit

    it "recognises auth failures" $ do
      classifyError "401 Unauthorized" `shouldBe` ErrAuth
      classifyError "invalid api key" `shouldBe` ErrAuth

    it "recognises timeouts" $ do
      classifyError "stream timed out after 20s" `shouldBe` ErrTimeout

    it "leaves everything else generic" $ do
      classifyError "provider error: 500" `shouldBe` ErrOther
      classifyError "tool failed" `shouldBe` ErrOther

  describe "errorLabel / errorHint" $ do
    it "labels each family distinctly" $ do
      errorLabel ErrRateLimit `shouldBe` "error · rate limited"
      errorLabel ErrAuth `shouldBe` "error · auth"
      errorLabel ErrTimeout `shouldBe` "error · timeout"
      errorLabel ErrOther `shouldBe` "error"

    it "only hints for actionable families" $ do
      errorHint ErrRateLimit `shouldSatisfy` (/= Nothing)
      errorHint ErrAuth `shouldSatisfy` (/= Nothing)
      errorHint ErrTimeout `shouldSatisfy` (/= Nothing)
      errorHint ErrOther `shouldBe` Nothing

  describe "metaLine" $ do
    it "renders model and token usage" $
      metaLine "deepseek-flash" (Just (mkUsage 100 20 120))
        `shouldBe` "model=deepseek-flash · in 100 · out 20"

    it "drops usage when it is empty or missing" $ do
      metaLine "m" (Just (mkUsage 0 0 0)) `shouldBe` "model=m"
      metaLine "m" Nothing `shouldBe` "model=m"

    it "drops the model when empty" $
      metaLine "" (Just (mkUsage 1 2 3)) `shouldBe` "in 1 · out 2"
