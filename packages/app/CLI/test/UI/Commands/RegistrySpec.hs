{-# LANGUAGE OverloadedStrings #-}

module UI.Commands.RegistrySpec (spec) where

import Test.Hspec
import UI.Commands.Registry
import Core.Types (configTheme, configLang, defaultCLIConfig)
import UI.I18n (Lang(..))
import UI.Render.Picker (piId)
import Data.Either (isLeft, isRight)
import qualified Data.Text as T
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.KeyMap as KM
import Data.Aeson (Value(..))
import qualified Data.ByteString.Lazy as BL
import qualified Data.Text.Encoding as TE
import Data.Maybe (mapMaybe)

spec :: Spec
spec = do
  describe "slashRegistry" $ do
    it "every command starts with a slash and has a unique name" $ do
      map scCommand slashRegistry `shouldSatisfy` all ("/" `T.isPrefixOf`)
      map scCommand slashRegistry `shouldSatisfy` unique
    it "contains the core command set" $ do
      map scCommand slashRegistry
        `shouldSatisfy` all (`elem` [ "/help", "/model", "/models", "/new"
                                    , "/sessions", "/delete", "/clear", "/status", "/settings"
                                    , "/plan", "/plugins", "/resume", "/approve", "/deny"
                                    , "/quit", "/exit" ])

  describe "pickerItems" $ do
    it "offers exactly the picker-enabled commands in registry order" $ do
      map piId (pickerItems En)
        `shouldBe` [ scCommand sc | sc <- slashRegistry, scPicker sc ]

    it "excludes parameter-requiring commands like /delete" $ do
      map piId (pickerItems En) `shouldNotContain` ["/delete"]

  describe "parseCommand /settings" $ do
    it "parses a bare /settings as ShowSettings" $ do
      parseCommand "/settings" `shouldBe` ShowSettings
    it "parses /settings key value as SetSetting" $ do
      parseCommand "/settings theme light" `shouldBe` SetSetting "theme" "light"
    it "parses multi-word values (rest is joined)" $ do
      parseCommand "/settings lang zh" `shouldBe` SetSetting "lang" "zh"
    it "parses a bare key with an empty value" $ do
      parseCommand "/settings theme" `shouldBe` SetSetting "theme" ""

  describe "settingKeys / parseSettingValue" $ do
    it "offers the canonical keys" $ do
      let want = ["host", "port", "model", "theme", "lang", "maxTokens", "timeout", "verbose"]
      want `shouldSatisfy` all (`elem` settingKeys)
    it "updates a text key from the base config" $ do
      case parseSettingValue En defaultCLIConfig "theme" "light" of
        Right cfg -> configTheme cfg `shouldBe` "light"
        Left e     -> expectationFailure (T.unpack e)
    it "parses integer and boolean keys" $ do
      parseSettingValue En defaultCLIConfig "port" "9999" `shouldSatisfy` isRight
      parseSettingValue En defaultCLIConfig "verbose" "true" `shouldSatisfy` isRight
    it "rejects unknown keys and bad numbers" $ do
      parseSettingValue En defaultCLIConfig "nope" "1" `shouldSatisfy` isLeft
      parseSettingValue En defaultCLIConfig "port" "abc" `shouldSatisfy` isLeft
    it "keeps zh error messages localised" $ do
      case parseSettingValue Zh defaultCLIConfig "port" "abc" of
        Left e  -> e `shouldBe` "值必须为整数：abc"
        Right _ -> expectationFailure "expected Left"

  describe "suggestSettingKey" $ do
    it "suggests a close key within edit distance 2" $ do
      suggestSettingKey "theem" `shouldBe` Just "theme"
      suggestSettingKey "hostt" `shouldBe` Just "host"
      suggestSettingKey "model" `shouldBe` Nothing
    it "returns Nothing for unrelated keys" $ do
      suggestSettingKey "zzzz" `shouldBe` Nothing
    it "embeds a suggestion into the unknown-key error" $ do
      case parseSettingValue En defaultCLIConfig "theem" "x" of
        Left e  -> e `shouldBe` "Unknown setting key: theem Did you mean: theme"
        Right _ -> expectationFailure "expected Left"
    it "localises the suggestion prefix in zh" $ do
      case parseSettingValue Zh defaultCLIConfig "theem" "x" of
        Left e  -> e `shouldBe` "未知设置项：theem 你是不是想设置：theme"
        Right _ -> expectationFailure "expected Left"

  describe "formatSettings" $ do
    it "shows a Chinese header in Zh" $ do
      T.lines (formatSettings Zh defaultCLIConfig) `shouldSatisfy` ((== "设置：") . head)
    it "shows the English header in En" $ do
      T.lines (formatSettings En defaultCLIConfig) `shouldSatisfy` ((== "Settings:") . head)
    it "echoes the effective lang value" $ do
      formatSettings En defaultCLIConfig `shouldSatisfy` T.isInfixOf ("lang        = " <> configLang defaultCLIConfig)

  describe "completions" $ do
    it "lists every canonical command" $ do
      completions `shouldBe` map scCommand slashRegistry

  describe "isKnownCommand" $ do
    it "accepts registered commands" $ do
      isKnownCommand "/model" `shouldBe` True
      isKnownCommand "/help" `shouldBe` True
    it "accepts parameterised forms" $ do
      isKnownCommand "/delete abc" `shouldBe` True
      isKnownCommand "/model deepseek-chat" `shouldBe` True
    it "rejects unknown and non-slash input" $ do
      isKnownCommand "/foo" `shouldBe` False
      isKnownCommand "hello" `shouldBe` False
      isKnownCommand "" `shouldBe` False

  describe "registryHelp" $ do
    it "has a header and one line per command" $ do
      T.lines (registryHelp En)
        `shouldSatisfy` ((== "Commands:") . head)
      length (T.lines (registryHelp En)) `shouldBe` 1 + length slashRegistry
    it "mentions every command and its description" $ do
      mapM_ (\sc -> do
        registryHelp En `shouldSatisfy` T.isInfixOf (scCommand sc)
        registryHelp En `shouldSatisfy` T.isInfixOf (scDesc sc))
        slashRegistry


  describe "settingsSchemaJson" $ do
    it "serialises every registered key with kind/description/default" $ do
      let rows = Aeson.eitherDecode (BL.fromStrict (TE.encodeUtf8 settingsSchemaJson)) :: Either String [Value]
      case rows of
        Left e  -> expectationFailure e
        Right vs -> do
          length vs `shouldBe` length settingKeyDocs
          mapMaybe keyOf vs `shouldBe` map fst3 settingKeyDocs
    it "defaults match the typed defaults for a couple of keys" $ do
      settingsSchemaJson `shouldSatisfy` T.isInfixOf "\"key\":\"lang\""
      settingsSchemaJson `shouldSatisfy` T.isInfixOf "\"default\":\"zh\""
  where
    keyOf (Object o) = case KM.lookup "key" o of Just (String k) -> Just k; _ -> Nothing
    keyOf _ = Nothing
    fst3 (a, _, _) = a

unique :: Eq a => [a] -> Bool
unique xs = length xs == length (dedup xs)
  where dedup [] = []
        dedup (x : rest) = x : dedup (filter (/= x) rest)