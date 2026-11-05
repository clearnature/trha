{-# LANGUAGE OverloadedStrings #-}

-- | 设置键的元数据与解析：@/settings <key> <value>@ 的键表、文档、取值解析、
-- 格式化、拼写建议，以及设置项 JSON schema（供 Web 端消费）。
--
-- 从 "UI.Commands.Registry" 拆出。两者本无关系——一个管「有哪些命令」，
-- 一个管「配置键怎么解析」，只是历史上同处一文件。
module UI.Commands.Registry.Settings
  ( settingKeys
  , settingKeyDocs
  , settingKeyHelp
  , parseSettingValue
  , formatSettings
  , suggestSettingKey
  , settingsSchemaJson
  , defaultFor
  ) where

import Data.Aeson (Value(..), object, toJSON, (.=))
import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Lazy as BL
import qualified Data.Text.Encoding as TE
import Data.List (minimumBy)
import Data.Ord (comparing)
import Data.Text (Text)
import qualified Data.Text as T
import Core.Types (CLIConfig(..), defaultCLIConfig)
import UI.I18n (Lang(..), tr)
import UI.Render.Picker (PickerItem(..))

settingKeys :: [Text]
settingKeys = map (\(k, _, _) -> k) settingKeyDocs

-- | Per-key documentation: (key, value kind, English description key).
-- Mirrors the schema metadata found in reference CLIs (qwen-code
-- settingsSchema: each key carries a type and a description; deepseek
-- config-catalog documents every settable option with its contract).
settingKeyDocs :: [(Text, Text, Text)]
settingKeyDocs =
  [ ("host",      "text", "Server host for the orchestration scheduler")
  , ("port",      "int",  "Port of the orchestration scheduler")
  , ("model",     "text", "Default model name for new sessions")
  , ("provider",  "text", "Preferred model provider (empty = kernel default)")
  , ("token",     "text", "Bearer token used against the scheduler")
  , ("proxy",     "text", "Proxy for remote targets: unset = env | none | http://host:port (loopback is always direct)")
  , ("scheme",    "text", "Scheduler transport: https (default) | http")
  , ("maxTokens", "int",  "Maximum tokens per completion")
  , ("timeout",   "int",  "HTTP request timeout in milliseconds")
  , ("retries",   "int",  "Retry count for failed requests")
  , ("verbose",   "bool", "Verbose logging")
  , ("theme",     "text", "TUI theme: tokyo-night | light")
  , ("lang",      "text", "Interface language: zh | en")
  , ("reasoningLanguage", "text", "Language the model reasons in: auto = follow the interface language")
  , ("metrics",   "text", "Status-line metrics (comma separated keys)")
  , ("markdown",  "bool", "Render assistant replies as markdown")
  , ("timestamps","bool", "Show message timestamps")
  , ("hints",     "bool", "Show the footer key hints")
  , ("bell",      "bool", "Ring the bell when a reply completes")
  ]

-- | One-line key reference for /settings (localised kinds/labels).
settingKeyHelp :: Lang -> Text
settingKeyHelp lang = T.unlines
  [ tr lang "Available keys:"
  , T.unlines [ "  " <> k <> " (" <> tr lang kindDesc <> ")"
              | (k, kindDesc, _) <- settingKeyDocs ]
  ]

-- | Parse a textual value for a known key, starting from the given
-- (current effective) configuration.  Errors are already localised.
parseSettingValue :: Lang -> CLIConfig -> Text -> Text -> Either Text CLIConfig
parseSettingValue lang cfg key raw =
  case T.toLower (T.strip key) of
    "host"      -> Right cfg { configHost = T.strip raw }
    "port"      -> fmap (\p -> cfg { configPort = p }) (parseInt raw)
    "model"     -> Right cfg { configModel = T.strip raw }
    "provider"  -> Right cfg { configProvider = T.strip raw }
    "token"     -> Right cfg { configToken = T.strip raw }
    "proxy"     -> Right cfg { configProxy = T.strip raw }
    "scheme"    -> case T.toLower (T.strip raw) of
      "https" -> Right cfg { configScheme = "https" }
      "http"  -> Right cfg { configScheme = "http" }
      other   -> Left (tr lang "Value must be http or https: " <> other)
    "maxtokens" -> fmap (\n -> cfg { configMaxTokens = n }) (parseInt raw)
    "timeout"   -> fmap (\n -> cfg { configTimeout = n }) (parseInt raw)
    "retries"   -> fmap (\n -> cfg { configRetries = n }) (parseInt raw)
    "verbose"   -> fmap (\b -> cfg { configVerbose = b }) (parseBool raw)
    "markdown"  -> fmap (\b -> cfg { configMarkdown = b }) (parseBool raw)
    "timestamps" -> fmap (\b -> cfg { configTimestamps = b }) (parseBool raw)
    "hints"     -> fmap (\b -> cfg { configHints = b }) (parseBool raw)
    "bell"      -> fmap (\b -> cfg { configBell = b }) (parseBool raw)
    "theme"     -> Right cfg { configTheme = T.strip raw }
    "lang"      -> Right cfg { configLang = T.strip raw }
    "reasoninglanguage" -> Right cfg { configReasoningLanguage = T.strip raw }
    "metrics"   -> Right cfg { configMetrics = T.strip raw }
    _ -> Left (tr lang "Unknown setting key: " <> key
               <> maybe "" (\sugg -> " " <> tr lang "Did you mean: " <> sugg) (suggestSettingKey key))
  where
    parseInt v = case reads (T.unpack (T.strip v)) of
      [(n, "")] -> Right n
      _         -> Left (tr lang "Value must be a whole number: " <> v)
    parseBool v = case T.toLower (T.strip v) of
      "true"  -> Right True
      "false" -> Right False
      "1"     -> Right True
      "0"     -> Right False
      _       -> Left (tr lang "Value must be true or false: " <> v)

-- | Human-readable rendering of an effective configuration.
formatSettings :: Lang -> CLIConfig -> Text
formatSettings lang cfg = T.unlines
  [ tr lang "Settings:"
  , "  host        = " <> configHost cfg
  , "  port        = " <> T.pack (show (configPort cfg))
  , "  model       = " <> configModel cfg
  , "  provider    = " <> configProvider cfg
  , "  token       = " <> configToken cfg
  , "  maxTokens   = " <> T.pack (show (configMaxTokens cfg))
  , "  timeout     = " <> T.pack (show (configTimeout cfg))
  , "  retries     = " <> T.pack (show (configRetries cfg))
  , "  verbose     = " <> (if configVerbose cfg then "true" else "false")
  , "  markdown    = " <> (if configMarkdown cfg then "true" else "false")
  , "  timestamps  = " <> (if configTimestamps cfg then "true" else "false")
  , "  hints       = " <> (if configHints cfg then "true" else "false")
  , "  bell        = " <> (if configBell cfg then "true" else "false")
  , "  theme       = " <> configTheme cfg
  , "  lang        = " <> configLang cfg
  , "  reasoningLanguage = " <> configReasoningLanguage cfg
  , "  scheme      = " <> configScheme cfg
  , "  " <> tr lang "(effective: layered defaults < ~/.trha/settings.yaml < project)"
  , ""
  , T.strip (settingKeyHelp lang)
  ]

-- | Suggest the closest known key when the user mistypes one (edit
-- distance <= 2, like the reference CLI's typo help).  'Nothing' when no
-- key is close enough.
suggestSettingKey :: Text -> Maybe Text
suggestSettingKey key
  | T.null key = Nothing
  | otherwise = case hits of
      []  -> Nothing
      _   -> Just (fst (minimumBy (comparing snd) hits))
  where
    hits = [ (k, lev key k) | k <- settingKeys, k /= key, lev key k <= 2 ]

-- | Classic Levenshtein edit distance.
lev :: Text -> Text -> Int
lev a b = go (T.unpack a) (T.unpack b)
  where
    go [] ys = length ys
    go xs [] = length xs
    go (x : xs) (y : ys)
      | x == y = go xs ys
      | otherwise = 1 + minimum [ go xs ys, go (x : xs) ys, go xs (y : ys) ]

      | otherwise = 1 + minimum [ go xs ys, go (x : xs) ys, go xs (y : ys) ]

-- | Default textual value of a key (from 'defaultCLIConfig'), used to fill
-- the machine-readable schema.
defaultFor :: Text -> Text
defaultFor k = case k of
  "host"      -> configHost def
  "port"      -> T.pack (show (configPort def))
  "token"     -> configToken def
  "proxy"     -> configProxy def
  "scheme"    -> configScheme def
  "model"     -> configModel def
  "maxTokens" -> T.pack (show (configMaxTokens def))
  "timeout"   -> T.pack (show (configTimeout def))
  "retries"   -> T.pack (show (configRetries def))
  "verbose"   -> boolT (configVerbose def)
  "theme"     -> configTheme def
  "lang"      -> configLang def
  "reasoningLanguage" -> configReasoningLanguage def
  "metrics"   -> configMetrics def
  "markdown"  -> boolT (configMarkdown def)
  "timestamps" -> boolT (configTimestamps def)
  "hints"     -> boolT (configHints def)
  "bell"      -> boolT (configBell def)
  _           -> ""
  where
    def = defaultCLIConfig
    boolT True = "true"
    boolT False = "false"

-- | Machine-readable settings schema (config-catalog style): one row per
-- key with kind, English description and the default value.
settingsSchemaJson :: Text
settingsSchemaJson = TE.decodeUtf8 (BL.toStrict (Aeson.encode rows))
  where
    rows = [ object
               [ "key" .= k
               , "kind" .= kind
               , "description" .= desc
               , "default" .= defaultFor k
               ]
           | (k, kind, desc) <- settingKeyDocs
           ]

-- | @/help@ 的完整输出：命令分类表 + 键位表。
--
-- 纯函数（只依赖同模块的 'registryHelp' 与翻译表），从 @UI.Brick@ 拆出后
-- 可以脱离终端单测——命令清单与键位说明都不该需要真终端才能验证。
