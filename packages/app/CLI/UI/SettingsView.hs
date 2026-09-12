{-# LANGUAGE OverloadedStrings #-}

-- | Pure rendering/view-model for the /settings panel (TUI) -- mirrors the
-- schema-driven settings list of reference CLIs (qwen-code SettingsDialog /
-- Claude Code /config): every setting row shows key, value (current or
-- default), type and a localised hint; editing applies per key.
--
-- Pure module -- no IO, no brick -- so everything here is unit-testable.
module UI.SettingsView
  ( SettingsEntry(..)
  , settingsEntries
  , filterEntries
  , isOverridden
  , entryRow
  , maskSecret
  , defaultHint
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Core.Types (CLIConfig(..), defaultCLIConfig)
import UI.I18n (Lang(..), tr)

-- | One setting shown in the panel (schema metadata + current value).
data SettingsEntry = SettingsEntry
  { seLabel   :: Text      -- ^ localised display name (shown in the panel)
  , seKey     :: Text      -- ^ stable key (also the edit target)
  , seKind    :: Text      -- ^ value kind: text | int | bool
  , seVal     :: Text      -- ^ current effective value
  , seDef     :: Text      -- ^ default value (from defaultCLIConfig)
  , seHint    :: Text      -- ^ localised one-line description
  , seOptions :: [Text]    -- ^ enum choices (empty = free-form)
  } deriving (Show, Eq)

-- | Build the panel rows from the effective configuration, ordered by
-- logical group (Connection / Model / Appearance) like reference panels.
settingsEntries :: Lang -> CLIConfig -> [SettingsEntry]
settingsEntries lang cfg = map mk ordered
  where
    raw :: [(Text, Text, Text, Text, Text)]
    raw = [ ("host", "text", tr lang "Server host for the orchestration scheduler", configHost cfg, configHost def)
          , ("port", "int", tr lang "Port of the orchestration scheduler", T.pack (show (configPort cfg)), T.pack (show (configPort def)))
          , ("token", "text", tr lang "Bearer token used against the scheduler", configToken cfg, configToken def)
          , ("model", "text", tr lang "Default model name for new sessions", configModel cfg, configModel def)
          , ("maxTokens", "int", tr lang "Maximum tokens per completion", T.pack (show (configMaxTokens cfg)), T.pack (show (configMaxTokens def)))
          , ("timeout", "int", tr lang "HTTP request timeout in milliseconds", T.pack (show (configTimeout cfg)), T.pack (show (configTimeout def)))
          , ("retries", "int", tr lang "Retry count for failed requests", T.pack (show (configRetries cfg)), T.pack (show (configRetries def)))
          , ("theme", "text", tr lang "TUI theme: tokyo-night | light", configTheme cfg, configTheme def)
          , ("lang", "text", tr lang "Interface language: zh | en", configLang cfg, configLang def)
          , ("verbose", "bool", tr lang "Verbose logging", if configVerbose cfg then "true" else "false", if configVerbose def then "true" else "false")
          , ("metrics", "text", tr lang "Status-line metrics (comma separated keys)", configMetrics cfg, configMetrics def)
          , ("markdown", "bool", tr lang "Render assistant replies as markdown", boolT (configMarkdown cfg), boolT (configMarkdown def))
          , ("timestamps", "bool", tr lang "Show message timestamps", boolT (configTimestamps cfg), boolT (configTimestamps def))
          , ("hints", "bool", tr lang "Show the footer key hints", boolT (configHints cfg), boolT (configHints def))
          , ("bell", "bool", tr lang "Ring the bell when a reply completes", boolT (configBell cfg), boolT (configBell def))
          ]
    boolT True = "true"
    boolT False = "false"
    groupKeys :: [[Text]]
    groupKeys = [ ["host", "port", "token"]            -- connection
                , ["model", "maxTokens", "timeout", "retries"]  -- model
                , ["theme", "lang", "verbose", "metrics", "markdown", "timestamps", "hints", "bell"]
                ]
    ordered = concatMap (\group -> [ e | e <- raw, fst5 e `elem` group ]) groupKeys
    fst5 (k, _, _, _, _) = k
    def = defaultCLIConfig
    mk (k, kind, hint, val, dv) = SettingsEntry (labelOf lang k) k kind val dv hint (enumChoices k)
    labelOf l k = tr l (case k of
      "host"      -> "Host"
      "port"      -> "Port"
      "token"     -> "Token"
      "model"     -> "Model"
      "maxTokens" -> "Max Tokens"
      "timeout"   -> "Timeout"
      "retries"   -> "Retries"
      "verbose"   -> "Verbose logging"
      "theme"     -> "Theme"
      "metrics"   -> "Status-line metrics"
      "markdown"  -> "Markdown rendering"
      "timestamps" -> "Timestamps"
      "hints"     -> "Footer hints"
      "bell"      -> "Reply bell"
      _           -> "Interface language")
    enumChoices "theme" = ["tokyo-night", "light"]
    enumChoices "lang"  = ["zh", "en"]
    enumChoices _       = []

-- | Case-insensitive filtering over key and hint (mirrors the search box
-- of reference settings panels).
filterEntries :: Text -> [SettingsEntry] -> [SettingsEntry]
filterEntries query entries
  | T.null q = entries
  | otherwise = filter matches entries
  where
    q = T.toLower (T.strip query)
    matches e =
      T.isInfixOf q (T.toLower (seKey e))
        || T.isInfixOf q (T.toLower (seHint e))

-- | True when the current value differs from the default (user override).
isOverridden :: SettingsEntry -> Bool
isOverridden e = seVal e /= seDef e

-- | One rendered row (kept under a sane width by the caller).
-- Format mirrors reference panels: key, current value, kind, hint.
entryRow :: Lang -> SettingsEntry -> Text
entryRow lang e = T.unwords
  [ seKey e
  , "="
  , valueDisplay
  , "[" <> seKind e <> "]"
  , seHint e
  ]
  where
    valueDisplay = if seKey e == "token" then maskSecret (seVal e) else seVal e

-- | Obscure secret-ish values (token) when displaying them.
maskSecret :: Text -> Text
maskSecret v
  | T.null v = "(empty)"
  | T.length v <= 4 = "****"
  | otherwise = T.take 4 v <> "****"

-- | Render the "(default: X)" suffix shown for values not yet overridden.
defaultHint :: Lang -> Text -> Text
defaultHint lang v = tr lang "(default: " <> v <> close
  where
    close = case lang of
      Zh -> "）"
      En -> ")"
