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
      parseLang "zh-Hans" `shouldBe` Zh
      parseLang "zh-Hans-CN" `shouldBe` Zh
      parseLang "zh-Hans-SG" `shouldBe` Zh
    it "maps English identifiers to En" $ do
      parseLang "en" `shouldBe` En
      parseLang "en-US" `shouldBe` En
    it "falls back to En for unknown values" $ do
      parseLang "xx" `shouldBe` En
      parseLang "" `shouldBe` En
    it "maps Traditional Chinese identifiers to ZhHant" $ do
      parseLang "zh-Hant" `shouldBe` ZhHant
      parseLang "bo" `shouldBe` Bo
      parseLang "ii" `shouldBe` Ii
      parseLang "my" `shouldBe` My
      parseLang "my-MM" `shouldBe` My
    it "maps the supported locales" $ do
      parseLang "fr" `shouldBe` Fr
      parseLang "es" `shouldBe` Es
      parseLang "ru" `shouldBe` Ru
      parseLang "th" `shouldBe` Th

  describe "langName (BCP 47 / ISO 15924)" $
    it "spells Chinese with script subtags, not region tags" $ do
      langName Zh `shouldBe` "zh-Hans"
      langName ZhHant `shouldBe` "zh-Hant"
      parseLang "zh-Hans" `shouldBe` Zh
      parseLang "zh-Hant" `shouldBe` ZhHant

  describe "tr" $ do
    it "keeps keys verbatim in English" $ do
      tr En "Show this help" `shouldBe` "Show this help"
      tr En "none" `shouldBe` "none"
    it "returns the key itself when no translation exists" $ do
      tr Zh "no-such-key-xyz" `shouldBe` "no-such-key-xyz"
    it "returns Chinese for translated keys" $ do
      tr Zh "Show this help" `shouldBe` "显示本帮助"
      tr Zh "Exit the application" `shouldBe` "退出程序"
    it "converts glyphs to Traditional Chinese for ZhHant" $ do
      toTraditional "会话设置" `shouldBe` "會話設置"
      tr ZhHant "Session: " `shouldBe` "會話："
      tr ZhHant "Show this help" `shouldBe` "顯示本幫助"
      -- status/UI vocabulary that used to stay Simplified under ZhHant
      tr ZhHant " · 就绪" `shouldBe` " · 就緒"
      tr ZhHant "统计" `shouldBe` "統計"
      tr ZhHant "详细日志" `shouldBe` "詳細日誌"
      tr ZhHant "操作系统" `shouldBe` "操作系統"
      tr ZhHant "导出转写…" `shouldBe` "導出轉寫…"
    it "uses the supported locale dictionaries and falls back to English" $ do
      tr Fr "Exit the application" `shouldBe` "Quitter l'application"
      tr Es "Commands:" `shouldBe` "Comandos:"
      tr Fr "Settings:" `shouldBe` "Paramètres :"
      tr Fr "context " `shouldBe` "contexte "
      tr Es "context " `shouldBe` "contexto "
      tr Ru "Error" `shouldBe` "Ошибка"
      -- Tibetan / Nuosu Yi skeletons: known words translated, rest falls back
      tr Bo "Ready" `shouldBe` "གྲ་སྒྲིག"
      tr Ii "Ready" `shouldBe` "ꄀꄉ"
      tr Bo "no-such-key-xyz" `shouldBe` "no-such-key-xyz"
      -- Burmese / Thai carry the common chrome keys
      tr My "Ready" `shouldBe` "အသင့်"
      tr My "Settings:" `shouldBe` "ဆက်တင်များ:"
      tr Th "Settings:" `shouldBe` "การตั้งค่า:"

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
