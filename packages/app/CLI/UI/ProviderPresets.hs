{-# LANGUAGE OverloadedStrings #-}

-- | Curated provider presets (MiMo's Popular / Other grouping).
--
-- Picking one pre-fills the wizard's name / kind / base URL / models; the
-- user still confirms and can edit every field, including ones the preset
-- cannot know (API key, custom effort ladder, vision models).
module UI.ProviderPresets
  ( Preset(..)
  , presets
  , popularPresets
  , otherPresets
  ) where

import Data.Text (Text)

data Preset = Preset
  { preName    :: Text
  , preKind    :: Text    -- ^ openai / anthropic / responses
  , preBaseUrl :: Text
  , preModels  :: [Text]
  , prePopular :: Bool
  } deriving (Show, Eq)

-- | Popular vendors first (the picker renders a "Popular" section, then
-- "Other"), matching MiMo's PROVIDER_PRIORITY / isPopularProvider split.
presets :: [Preset]
presets =
  [ Preset "deepseek" "openai" "https://api.deepseek.com/v1"
      ["deepseek-chat", "deepseek-reasoner"] True
  , Preset "openai" "openai" "https://api.openai.com/v1"
      ["gpt-4o", "gpt-4o-mini", "o3"] True
  , Preset "anthropic" "anthropic" "https://api.anthropic.com/v1"
      ["claude-sonnet-4", "claude-opus-4"] True
  , Preset "openrouter" "openai" "https://openrouter.ai/api/v1"
      ["openai/gpt-4o", "anthropic/claude-sonnet-4"] True
  , Preset "moonshot" "openai" "https://api.moonshot.cn/v1"
      ["moonshot-v1-8k"] False
  , Preset "siliconflow" "openai" "https://api.siliconflow.cn/v1"
      ["deepseek-ai/DeepSeek-V3"] False
  , Preset "ollama" "openai" "http://localhost:11434/v1"
      ["llama3.2"] False
  , Preset "lmstudio" "openai" "http://localhost:1234/v1"
      ["local-model"] False
  ]

popularPresets :: [Preset]
popularPresets = filter prePopular presets

otherPresets :: [Preset]
otherPresets = filter (not . prePopular) presets
