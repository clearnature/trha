{-# LANGUAGE OverloadedStrings #-}

module UI.Commands.RegistrySpec (spec) where

import Test.Hspec
import UI.Commands.Registry
import Core.Types (configTheme, configLang, configReasoningLanguage, defaultCLIConfig)
import UI.I18n (Lang(..))
import UI.Render.Picker (piId)
import Data.Either (isLeft, isRight)
import Data.Char (isAsciiLower, isDigit)
import Data.List (nub, sort)
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
                                    , "/shell"
                                    , "/attachments", "/clear-attachments", "/mcp", "/lsp"
                                    , "/preset", "/hooks", "/paste", "/vim", "/output-style"
                                    , "/session-info", "/transcript", "/retry", "/btw", "/workspace", "/recap", "/queue", "/steer"
                                    , "/fork", "/branch", "/goal", "/switch", "/loop", "/graph", "/workflow", "/currency"
                                    , "/cls", "/ask-timeout", "/reasoning-language"
                                    , "/todo", "/tree", "/agents", "/sandbox", "/rename", "/tag", "/quit", "/exit", "/stop"
                                    , "/rewind", "/restore", "/auth", "/update", "/reload-plugins"
                                    , "/init", "/review", "/compress"
                                    , "/cd", "/tools", "/permissions", "/history", "/about", "/summary", "/forget"
                                    , "/ctx", "/effort" ])

    -- 一致性不变量：注册表是「命令存在」的唯一真相，那么每条注册命令都必须
    -- 能被 parseCommand 认出来。落到 Unknown 就说明「声明了却没接线」——
    -- 用户会在 TUI 里看到命令存在、执行却得到未识别。
    it "commandArgs 参数表：键都是注册命令且参数词合法（小写词）" $ do
      mapM_ (\(cmd, args) -> do
               isKnownCommand cmd `shouldBe` True
               mapM_ (\(k, _d) ->
                 T.all (\ch -> ch `elem` ['a'..'z'] || ch == '-' || ch `elem` ['0'..'9']) k
                   `shouldBe` True) args)
            commandArgs
    it "/stop parses to StopRequest (tmux 实测曾派发成 Loop——回归钉)" $ do
      parseCommand "/stop" `shouldBe` StopRequest
      parseCommand "/stop confirm" `shouldBe` StopConfirmed
      parseCommand "/loop" `shouldBe` Loop ""
    it "每条注册命令都能被 parseCommand 解析（不落到 Unknown）" $ do
      let isUnknown (Unknown _) = True
          isUnknown _          = False
          unparsable = [ scCommand c
                       | c <- slashRegistry
                       , isUnknown (parseCommand (scCommand c)) ]
      unparsable `shouldBe` []

    -- 另一侧：TUI 分派里出现、但注册表没声明的命令 = 孤儿命令。
    -- 它们能被响应，却不会出现在 /help 与补全里，用户无从发现。
    --
    -- /ctx 与 /effort 曾被登记为「已知例外」：那时它们只在 UI.Brick.handleSlash
    -- 有实现，parseCommandBase 从没解析出对应的 Command 构造子（SetCtx / Effort
    -- 其实早就存在、executeCommand 也早有实现，只是没有解析入口）。补齐解析后
    -- 例外清零——本条断言现在要求「零孤儿」。
    it "handleSlash 里出现的命令都在注册表中（无孤儿命令）" $ do
      src <- readFile "UI/Brick.hs"
      let registered = map scCommand slashRegistry
          orphans    = [ c | c <- slashCommandsIn (T.pack src)
                           , c `notElem` registered ]
      orphans `shouldBe` []

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
    -- REPL 补全 = 注册表里标了 SRepl 的命令（T4–T8 补全后逐步扩到全表）。
    it "equals the SRepl-capable subset of the registry (surface-gated)" $ do
      completions `shouldBe`
        [ scCommand sc | sc <- slashRegistry, SRepl `elem` scSurfaces sc ]
    it "REPL 补全不推荐只在 TUI 实现的命令（占位期保护）" $ do
      completions `shouldNotSatisfy` elem "/home"
      completions `shouldNotSatisfy` elem "/copy"
      completions `shouldNotSatisfy` elem "/verbose"
      completions `shouldNotSatisfy` elem "/clear"

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
      T.lines (registryHelp STui En)
        `shouldSatisfy` ((== "Commands:") . head)
      -- +1 blank line, + "Keys:" and four key lines
      length (T.lines (registryHelp STui En))
        `shouldBe` 1 + length commandGroups + length slashRegistry + 6
    it "documents the shell keys next to the commands" $ do
      registryHelp STui En `shouldSatisfy` T.isInfixOf "Ctrl+C"
      registryHelp STui En `shouldSatisfy` T.isInfixOf "Ctrl+D"
      registryHelp STui En `shouldSatisfy` T.isInfixOf "/stop"
    it "names every group" $
      mapM_ (\g -> registryHelp STui En `shouldSatisfy` T.isInfixOf (groupKey g)) commandGroups
    it "mentions every command and its description" $ do
      mapM_ (\sc -> do
        registryHelp STui En `shouldSatisfy` T.isInfixOf (scCommand sc)
        registryHelp STui En `shouldSatisfy` T.isInfixOf (scDesc sc))
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

-- | 从源码中取出所有 @"/xxx"@ 形式的字符串字面量（去重）。
--
-- 'handleSlash' 是函数、无法在测试里枚举，所以把 TUI 分派静态转成命令清单
-- 与注册表比对。只认「斜杠 + 小写字母开头 + 字母/数字/连字符」：这样既排除
-- @"/"@ 这类路径分隔符、@"/api/v3"@ 这类 URL 片段，也排除 @"/3@ 这类被切词
-- 撕开的碎片。
slashCommandsIn :: T.Text -> [T.Text]
slashCommandsIn src = nub
  [ c
  | tok <- T.words src
  , Just rest <- [T.stripPrefix "\"" tok]
  , let c = T.takeWhile (/= '"') rest
  , "/" `T.isPrefixOf` c
  , T.length c > 1
  , T.all (\ch -> ch == '-' || ch == '/' || isAsciiLower ch || isDigit ch) c
  , maybe False (isAsciiLower . fst) (T.uncons (T.drop 1 c))
  ]
