{-# LANGUAGE OverloadedStrings #-}

module UI.SettingsViewSpec (spec) where

import Test.Hspec
import UI.SettingsView
import Core.Types (defaultCLIConfig)
import UI.I18n (Lang(..))
import qualified Data.Text as T

spec :: Spec
spec = do
  describe "settingsEntries" $ do
    it "exposes all canonical keys in order" $ do
      map seKey (settingsEntries En defaultCLIConfig)
        `shouldBe` ["host", "port", "token", "proxy", "model", "maxTokens", "timeout", "retries", "theme", "lang", "verbose", "metrics", "markdown", "timestamps", "hints", "bell"]
    it "carries kind metadata for each row" $ do
      let byKey k = head [ e | e <- settingsEntries En defaultCLIConfig, seKey e == k ]
      seKind (byKey "port") `shouldBe` "int"
      seKind (byKey "verbose") `shouldBe` "bool"
      seKind (byKey "lang") `shouldBe` "text"
    it "echoes effective values from the passed config" $ do
      let cfg = defaultCLIConfig
          byKey k = head [ e | e <- settingsEntries En cfg, seKey e == k ]
      seVal (byKey "lang") `shouldBe` "zh"

  describe "maskSecret" $ do
    it "hides short secrets fully" $ do
      maskSecret "abc" `shouldBe` "****"
    it "keeps only the first four characters of longer secrets" $ do
      maskSecret "sk-0123456789" `shouldBe` "sk-0****"
    it "labels empty secrets" $ do
      maskSecret "" `shouldBe` "(empty)"

  describe "entryRow" $ do
    it "renders key = value [kind] hint" $ do
      let row = entryRow En (head (settingsEntries En defaultCLIConfig))
      row `shouldSatisfy` T.isInfixOf "host = localhost [text]"
    it "uses the Chinese hint set under Zh" $ do
      let e = head (settingsEntries Zh defaultCLIConfig)
      seHint e `shouldSatisfy` T.isInfixOf "编排调度器"

  describe "filterEntries" $ do
    it "returns everything for an empty query" $ do
      length (filterEntries "" (settingsEntries En defaultCLIConfig)) `shouldBe` 16
    it "filters by key substring (case-insensitive)" $ do
      map seKey (filterEntries "max" (settingsEntries En defaultCLIConfig))
        `shouldBe` ["maxTokens"]
      map seKey (filterEntries "Theme" (settingsEntries En defaultCLIConfig))
        `shouldBe` ["theme"]
    it "also matches the hint text" $ do
      map seKey (filterEntries "界面" (settingsEntries Zh defaultCLIConfig))
        `shouldBe` ["lang"]

  describe "isOverridden" $ do
    it "flags values that differ from the default" $ do
      let e = head (settingsEntries En defaultCLIConfig)
      isOverridden e `shouldBe` False

  describe "seLabel" $ do
    it "localises the display name" $ do
      let byKey l k = head [ e | e <- settingsEntries l defaultCLIConfig, seKey e == k ]
      seLabel (byKey En "theme") `shouldBe` "Theme"
      seLabel (byKey En "lang") `shouldBe` "Interface language"
      seLabel (byKey Zh "theme") `shouldBe` "主题"
      seLabel (byKey Zh "port") `shouldBe` "端口"

  describe "seOptions" $ do
    it "exposes enum choices for theme and lang" $ do
      let byKey k = head [ e | e <- settingsEntries En defaultCLIConfig, seKey e == k ]
      seOptions (byKey "theme") `shouldBe` ["tokyo-night", "light"]
      seOptions (byKey "lang") `shouldBe` ["zh", "en"]
      seOptions (byKey "host") `shouldBe` []

  describe "defaultHint" $ do
    it "wraps the value in a localized label" $ do
      defaultHint Zh "tokyo-night" `shouldBe` "（默认：tokyo-night）"
      defaultHint En "zh" `shouldBe` "(default: zh)"
