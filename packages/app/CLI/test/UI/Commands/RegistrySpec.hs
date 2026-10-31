{-# LANGUAGE OverloadedStrings #-}

module UI.Commands.RegistrySpec (spec) where

import Test.Hspec
import UI.Commands.Registry
import Core.Types (configTheme, configLang, configReasoningLanguage, defaultCLIConfig)
import UI.I18n (Lang(..))
import UI.Render.Picker (piId)
import Data.Either (isLeft, isRight)
import Data.List (sort)
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
        `shouldSatisfy` all (`elem` [ "/help", "/model", "/models", "/provider", "/new"
                                    , "/sessions", "/delete", "/clear", "/status", "/settings"
                                    , "/plan", "/plugins", "/resume", "/approve", "/deny"
                                    , "/skip", "/reject", "/abandon", "/export", "/home"
                                    , "/stash", "/fav", "/skills", "/theme", "/mode", "/copy", "/verbose"
                                    , "/mouse", "/language", "/diff", "/context"
                                    , "/doctor", "/memory", "/remember", "/stats", "/usage", "/compact"
                                    , "/attachments", "/clear-attachments", "/mcp", "/lsp"
                                    , "/preset", "/hooks", "/paste", "/vim", "/output-style"
                                    , "/session-info", "/transcript", "/retry", "/btw", "/workspace", "/recap", "/queue", "/steer"
                                    , "/fork", "/branch", "/goal", "/switch", "/loop", "/graph", "/workflow", "/currency"
                                    , "/cls", "/ask-timeout", "/reasoning-language"
                                    , "/todo", "/tree", "/agents", "/sandbox", "/rename", "/tag", "/quit", "/exit", "/stop" ])

  describe "pickerItems" $ do
    it "offers exactly the picker-enabled commands in registry order" $ do
      map piId (pickerItems En)
        `shouldBe` [ scCommand sc | sc <- slashRegistry, scPicker sc ]

    it "excludes parameter-requiring commands like /delete" $ do
      map piId (pickerItems En) `shouldNotContain` ["/delete"]

  describe "parseCommand /diff /context /doctor /memory /remember" $ do
    it "parses the read-only diagnostics" $ do
      parseCommand "/diff" `shouldBe` ShowDiff
      parseCommand "/context" `shouldBe` ShowContext
      parseCommand "/doctor" `shouldBe` Doctor
      parseCommand "/memory" `shouldBe` ShowMemory
      parseCommand "/remember  note " `shouldBe` Remember "note"
      parseCommand "/stats" `shouldBe` ShowStats
      parseCommand "/usage" `shouldBe` ShowUsage
      parseCommand "/compact" `shouldBe` Compact ""
      parseCommand "/compact keep decisions" `shouldBe` Compact "keep decisions"
      parseCommand "/attachments" `shouldBe` ShowAttachments
      parseCommand "/clear-attachments" `shouldBe` ClearAttachments
      parseCommand "/mcp" `shouldBe` ShowMcp
      parseCommand "/lsp" `shouldBe` ShowLsp
      parseCommand "/preset" `shouldBe` ShowPresets
      parseCommand "/hooks" `shouldBe` ShowHooks
      parseCommand "/paste note" `shouldBe` Paste "note"
      parseCommand "/vim" `shouldBe` EditPrompt
      parseCommand "/output-style" `shouldBe` OutputStyle Nothing
      parseCommand "/output-style concise" `shouldBe` OutputStyle (Just "concise")
      parseCommand "/session-info" `shouldBe` SessionInfoView
      parseCommand "/transcript" `shouldBe` TranscriptView
      parseCommand "/retry" `shouldBe` Retry
      parseCommand "/btw what changed?" `shouldBe` Btw "what changed?"
      parseCommand "/recap" `shouldBe` Recap
      parseCommand "/queue" `shouldBe` Queue Nothing
      parseCommand "/queue next thing" `shouldBe` Queue (Just "next thing")
      parseCommand "/steer focus on tests" `shouldBe` Steer "focus on tests"
      parseCommand "/fork alt approach" `shouldBe` Fork "alt approach"
      parseCommand "/branch" `shouldBe` Branch
      parseCommand "/goal" `shouldBe` GoalView
      parseCommand "/switch" `shouldBe` SwitchProvider Nothing
      parseCommand "/switch deepseek" `shouldBe` SwitchProvider (Just "deepseek")
      parseCommand "/loop 5m check the build" `shouldBe` Loop "5m check the build"
      parseCommand "/graph" `shouldBe` Graph
      parseCommand "/workflow review" `shouldBe` Workflow "review"
      parseCommand "/currency" `shouldBe` Currency ""
      parseCommand "/currency set USD 0.14" `shouldBe` Currency "set USD 0.14"
      parseCommand "/cls" `shouldBe` Cls
      parseCommand "/ask-timeout" `shouldBe` AskTimeout Nothing
      parseCommand "/ask-timeout 120" `shouldBe` AskTimeout (Just "120")
      parseCommand "/reasoning-language" `shouldBe` ReasoningLanguage Nothing
      parseCommand "/reasoning-language zh-Hans" `shouldBe` ReasoningLanguage (Just "zh-Hans")

  describe "parseCommand /language" $ do
    it "parses a bare /language as a query" $
      parseCommand "/language" `shouldBe` SetLanguage Nothing
    it "parses /language zh as a switch" $
      parseCommand "/language zh-Hans" `shouldBe` SetLanguage (Just "zh-Hans")

  describe "parseCommand /mouse" $ do
    it "parses a bare /mouse as a query" $
      parseCommand "/mouse" `shouldBe` SetMouseCapture Nothing
    it "parses /mouse off as native terminal selection" $
      parseCommand "/mouse off" `shouldBe` SetMouseCapture (Just False)
    it "parses /mouse on as in-app capture" $
      parseCommand "/mouse on" `shouldBe` SetMouseCapture (Just True)

  describe "parseCommand /settings" $ do
    it "parses a bare /settings as ShowSettings" $ do
      parseCommand "/settings" `shouldBe` ShowSettings
    it "parses /settings key value as SetSetting" $ do
      parseCommand "/settings theme light" `shouldBe` SetSetting "theme" "light"
    it "parses multi-word values (rest is joined)" $ do
      parseCommand "/settings lang zh-Hans" `shouldBe` SetSetting "lang" "zh-Hans"
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
    it "updates the reasoning language through the settings panel key" $ do
      case parseSettingValue En defaultCLIConfig "reasoningLanguage" "zh-Hant" of
        Right cfg -> configReasoningLanguage cfg `shouldBe` "zh-Hant"
        Left e    -> expectationFailure (T.unpack e)
      "reasoningLanguage" `elem` settingKeys `shouldBe` True
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
    it "has a header, one line per group and per command, plus the key section" $ do
      T.lines (registryHelp En)
        `shouldSatisfy` ((== "Commands:") . head)
      -- +1 blank line, + "Keys:" and four key lines
      length (T.lines (registryHelp En))
        `shouldBe` 1 + length commandGroups + length slashRegistry + 6
    it "documents the shell keys next to the commands" $ do
      registryHelp En `shouldSatisfy` T.isInfixOf "Ctrl+C"
      registryHelp En `shouldSatisfy` T.isInfixOf "Ctrl+D"
      registryHelp En `shouldSatisfy` T.isInfixOf "/stop"
    it "names every group" $
      mapM_ (\g -> registryHelp En `shouldSatisfy` T.isInfixOf (groupKey g)) commandGroups
    it "mentions every command and its description" $ do
      mapM_ (\sc -> do
        registryHelp En `shouldSatisfy` T.isInfixOf (scCommand sc)
        registryHelp En `shouldSatisfy` T.isInfixOf (scDesc sc))
        slashRegistry

  describe "command groups" $ do
    it "lists every command exactly once" $ do
      let assigned = concatMap snd groupMembers
      length assigned `shouldBe` length slashRegistry
      sort assigned `shouldBe` sort (map scCommand slashRegistry)
    it "keeps the group order stable" $
      commandGroups `shouldBe` [ GSession, GHistory, GPlan, GModel, GContext
                               , GTools, GInput, GAppearance, GSettings, GHelp ]
    it "groups the picker items without losing any" $ do
      let total = sum [ length items | (_, items) <- pickerItemsGrouped En ]
      total `shouldBe` length (pickerItems En)
    it "localises group headings bilingually" $ do
      groupTitle Zh GSession `shouldBe` "会话 session"
      groupTitle En GSession `shouldBe` "session"


  describe "command coverage" $ do
    it "every registered command parses to a non-Unknown command" $
      [ (scCommand c, parseCommand (scCommand c)) | c <- slashRegistry ]
        `shouldSatisfy` all isParsed
    it "has unique command names" $
      map scCommand slashRegistry `shouldSatisfy` unique

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
      settingsSchemaJson `shouldSatisfy` T.isInfixOf "\"default\":\"zh-Hans\""
  where
    keyOf (Object o) = case KM.lookup "key" o of Just (String k) -> Just k; _ -> Nothing
    keyOf _ = Nothing
    fst3 (a, _, _) = a

unique :: Eq a => [a] -> Bool
unique xs = length xs == length (dedup xs)
  where dedup [] = []
        dedup (x : rest) = x : dedup (filter (/= x) rest)

isParsed :: (T.Text, Command) -> Bool
isParsed (_, Unknown _) = False
isParsed _              = True
