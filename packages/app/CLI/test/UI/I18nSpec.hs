{-# LANGUAGE OverloadedStrings #-}

module UI.I18nSpec (spec) where

import Test.Hspec
import UI.I18n
import UI.Commands.Registry (slashRegistry, SlashCommand(..), registryHelp)
import qualified Data.Text as T

spec :: Spec
spec = do
  describe "parseLang" $ do
    it "maps Chinese identifiers to Zh" $ do
      parseLang "zh" `shouldBe` Zh
      parseLang "zh-CN" `shouldBe` Zh
      parseLang "zh-cn" `shouldBe` Zh
      parseLang "cn" `shouldBe` Zh
      parseLang "中文" `shouldBe` Zh
    it "maps English identifiers to En" $ do
      parseLang "en" `shouldBe` En
      parseLang "en-US" `shouldBe` En
    it "falls back to En for unknown values" $ do
      parseLang "fr" `shouldBe` En
      parseLang "" `shouldBe` En

  describe "tr" $ do
    it "keeps keys verbatim in English" $ do
      tr En "Show this help" `shouldBe` "Show this help"
      tr En "none" `shouldBe` "none"
    it "returns the key itself when no translation exists" $ do
      tr Zh "no-such-key-xyz" `shouldBe` "no-such-key-xyz"
    it "returns Chinese for translated keys" $ do
      tr Zh "Show this help" `shouldBe` "显示本帮助"
      tr Zh "Exit the application" `shouldBe` "退出程序"

  describe "command registry coverage" $ do
    it "translates every registered command description in Zh" $ do
      mapM_ (\sc -> tr Zh (scDesc sc) `shouldNotBe` scDesc sc) slashRegistry
    it "keeps command names untranslated in the Zh help text" $ do
      let help = registryHelp Zh
      mapM_ (\sc -> help `shouldSatisfy` T.isInfixOf (scCommand sc)) slashRegistry
    it "prefixes the Zh help with a Chinese header" $ do
      T.lines (registryHelp Zh) `shouldSatisfy` ((== "命令：") . head)
    it "prefixes the En help with the English header" $ do
      T.lines (registryHelp En) `shouldSatisfy` ((== "Commands:") . head)
