{-# LANGUAGE OverloadedStrings #-}

-- | Pure pieces of the @trha setup@ questionnaire.
--
-- The interactive I/O lives in "UI.SetupWizard"; everything that decides
-- *what* the answers mean (which choices are offered, how a typed answer maps
-- to one, how they land in 'CLIConfig') is here so it can be unit-tested
-- without a terminal.
module UI.Setup
  ( SetupAnswers(..)
  , emptyAnswers
  , applyAnswers
  , setupSummary
  , choiceAt
  , langChoices
  , themeChoices
  , reasoningChoices
  , providerChoices
    -- * Post-setup self-check
  , CheckItem(..)
  , renderCheck
  ) where

import Core.Types (CLIConfig(..))
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import UI.ProviderPresets (Preset(..), presets)

-- | One answer per question; 'Nothing' means "keep what is configured".
data SetupAnswers = SetupAnswers
  { saLang      :: Maybe Text   -- ^ interface language tag
  , saTheme     :: Maybe Text
  , saReasoning :: Maybe Text   -- ^ auto | zh-Hans | …
  , saProvider  :: Maybe Text   -- ^ provider name (a preset, or typed)
  , saModel     :: Maybe Text
  , saApiKey    :: Maybe Text   -- ^ blank / absent = leave the stored key alone
  } deriving (Show, Eq)

emptyAnswers :: SetupAnswers
emptyAnswers = SetupAnswers Nothing Nothing Nothing Nothing Nothing Nothing

-- | Fold the answers onto a configuration (unanswered fields are kept).
applyAnswers :: CLIConfig -> SetupAnswers -> CLIConfig
applyAnswers cfg a = cfg
  { configLang              = fromMaybe (configLang cfg) (saLang a)
  , configTheme             = fromMaybe (configTheme cfg) (saTheme a)
  , configReasoningLanguage = fromMaybe (configReasoningLanguage cfg) (saReasoning a)
  , configProvider          = fromMaybe (configProvider cfg) (saProvider a)
  , configModel             = fromMaybe (configModel cfg) (saModel a)
  }

-- | Human-readable summary printed at the end of the wizard.
setupSummary :: CLIConfig -> [Text]
setupSummary cfg =
  [ "lang = " <> configLang cfg
  , "theme = " <> configTheme cfg
  , "reasoningLanguage = " <> configReasoningLanguage cfg
  , "provider = " <> blankDash (configProvider cfg)
  , "model = " <> configModel cfg
  ]
  where
    blankDash t = if T.null (T.strip t) then "—" else t

-- | Options per question (1-based index in the prompt).
langChoices :: [Text]
langChoices = ["zh-Hans", "zh-Hant", "en"]

themeChoices :: [Text]
themeChoices = ["tokyo-night", "light"]

reasoningChoices :: [Text]
reasoningChoices = "auto" : langChoices

-- | Provider names offered by the wizard, popular vendors first.
providerChoices :: [Text]
providerChoices = map preName presets

-- | One line of the post-setup self-check.
data CheckItem = CheckItem
  { ciLabel  :: Text
  , ciOk     :: Bool
  , ciDetail :: Text
  } deriving (Show, Eq)

-- | @  ✓ label  detail@ (or @✗@ when the check failed).
renderCheck :: CheckItem -> Text
renderCheck c =
  (if ciOk c then "  ✓ " else "  ✗ ") <> ciLabel c
    <> (if T.null (ciDetail c) then "" else "  " <> ciDetail c)

-- | Resolve a typed answer against a choice list.
--
-- Blank means "keep the current value" ('Nothing'); a 1-based index or an
-- exact case-insensitive name picks that choice; anything else is treated as
-- "keep" as well (the wizard re-prompts on blanks only).
choiceAt :: [Text] -> Text -> Maybe Text
choiceAt choices raw
  | T.null t = Nothing
  | Just n <- readIndex t, n >= 1, n <= length choices = Just (choices !! (n - 1))
  | otherwise = case [ c | c <- choices, T.toLower c == t ] of
      (c : _) -> Just c
      []      -> Nothing
  where
    t = T.toLower (T.strip raw)
    readIndex s = case reads (T.unpack s) :: [(Int, String)] of
      [(n, "")] -> Just n
      _         -> Nothing
