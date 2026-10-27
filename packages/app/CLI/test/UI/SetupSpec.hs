{-# LANGUAGE OverloadedStrings #-}

module UI.SetupSpec (spec) where

import Test.Hspec
import qualified Data.Text as T

import Core.Types (configLang, configModel, configProvider, configTheme, configReasoningLanguage, defaultCLIConfig)
import UI.Setup

spec :: Spec
spec = do
  describe "applyAnswers" $ do
    it "keeps every unanswered field" $ do
      let cfg = applyAnswers defaultCLIConfig emptyAnswers
      cfg `shouldBe` defaultCLIConfig

    it "overlays the answered fields" $ do
      let cfg = applyAnswers defaultCLIConfig SetupAnswers
            { saLang = Just "en"
            , saTheme = Just "light"
            , saReasoning = Just "en"
            , saProvider = Just "anthropic"
            , saModel = Just "claude-sonnet-4"
            , saApiKey = Nothing
            }
      configLang cfg `shouldBe` "en"
      configTheme cfg `shouldBe` "light"
      configReasoningLanguage cfg `shouldBe` "en"
      configProvider cfg `shouldBe` "anthropic"
      configModel cfg `shouldBe` "claude-sonnet-4"

    it "leaves fields alone when only some answers arrive" $ do
      let cfg = applyAnswers defaultCLIConfig emptyAnswers { saTheme = Just "light" }
      configTheme cfg `shouldBe` "light"
      configLang cfg `shouldBe` configLang defaultCLIConfig
      configModel cfg `shouldBe` configModel defaultCLIConfig

  describe "choiceAt" $ do
    it "maps a 1-based index to the choice" $ do
      choiceAt langChoices "1" `shouldBe` Just "zh-Hans"
      choiceAt langChoices "3" `shouldBe` Just "en"
    it "maps an exact name, case-insensitively" $ do
      choiceAt themeChoices "LIGHT" `shouldBe` Just "light"
    it "treats blank and out-of-range answers as keep" $ do
      choiceAt langChoices "" `shouldBe` Nothing
      choiceAt langChoices "9" `shouldBe` Nothing
      choiceAt langChoices "nope" `shouldBe` Nothing

  describe "choices" $ do
    it "offers auto plus the interface languages for reasoning" $
      reasoningChoices `shouldSatisfy` ((== "auto") . head)
    it "lists the curated providers" $ do
      providerChoices `shouldSatisfy` elem "deepseek"
      providerChoices `shouldSatisfy` elem "anthropic"

  describe "setupSummary" $
    it "prints every field the wizard can change" $ do
      let rows = setupSummary defaultCLIConfig
      rows `shouldSatisfy` any (T.isPrefixOf "lang = ")
      rows `shouldSatisfy` any (T.isPrefixOf "reasoningLanguage = ")
      rows `shouldSatisfy` any (T.isPrefixOf "provider = ")
