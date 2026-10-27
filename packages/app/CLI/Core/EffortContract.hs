{-# LANGUAGE OverloadedStrings #-}

-- | Per-vendor reasoning-effort contracts (ported from Reasonix's
-- @internal/contract/provider/zhipu_effort.go@ + @vendor.go@).
--
-- Different vendors expose different depth ladders and even different wire
-- spellings.  The contract is looked up by (base URL host, model id); a model
-- with no documented ladder falls back to the generic five levels, and a
-- probed @efforts@ list (the kernel's @ProviderEntry.peEfforts@) still wins
-- when present.
module Core.EffortContract
  ( EffortContract(..)
  , contractFor
  , levelsFor
  , vendorOf
  ) where

import Data.Char (toLower)
import Data.List (isInfixOf)
import Data.Text (Text)
import qualified Data.Text as T

data EffortContract = EffortContract
  { ecLevels      :: [Text]   -- ^ /effort menu order
  , ecDefault     :: Text     -- ^ what the API applies when omitted
  , ecThinkingOff :: [Text]   -- ^ levels that switch thinking off
  , ecForced      :: Bool     -- ^ thinking cannot be disabled at all
  , ecField       :: Text     -- ^ wire field that carries the level
  } deriving (Show, Eq)

-- | Recognise the vendor from the endpoint host (Reasonix matches exact hosts).
vendorOf :: Text -> Text
vendorOf base
  | host `has` ["bigmodel.cn", "open.bigmodel.cn", "z.ai", "api.z.ai"] = "zhipu"
  | host `has` ["longcat.chat", "api.longcat.chat"] = "longcat"
  | host `has` ["api.moonshot.cn", "api.moonshot.ai"] = "kimi"
  | host `has` ["ollama.com"] = "ollama-cloud"
  | host `has` ["minimaxi.com", "api.minimaxi.com"] = "minimax"
  | host `has` ["tokenrhythm.studio"] = "tokenrhythm"
  | host `has` ["api.deepseek.com"] = "deepseek"
  | host `has` ["api.anthropic.com"] = "anthropic"
  | host `has` ["api.openai.com"] = "openai"
  | otherwise = ""
  where
    host = T.toLower base
    has h pats = any (`isInfixOf` T.unpack h) pats

-- | The documented ladder for (baseUrl, model), or the generic fallback.
-- | The contract is (vendor, protocol, model): the same model reached over
-- the OpenAI chat wire, the Anthropic messages wire or the Responses wire
-- exposes a different field and sometimes a different ladder.
contractFor :: Text -> Text -> Text -> EffortContract
contractFor base kind model
  | vendorOf base == "zhipu", kind /= "openai" = binaryGlm
  | vendorOf base == "zhipu" = zhipu m
  | kind == "anthropic" =
      EffortContract ["auto", "low", "medium", "high"] "auto" [] False
        "thinking.budget_tokens"
  | kind == "responses" =
      EffortContract ["minimal", "low", "medium", "high"] "medium" [] False
        "reasoning.effort"
  | vendorOf base == "openai" || vendorOf base == "deepseek" =
      EffortContract ["minimal", "low", "medium", "high"] "medium" [] False
        "reasoning_effort"
  | otherwise = generic
  where
    m = T.toLower (T.strip model)

-- | GLM depth models, keyed by exact id (Reasonix's table).
zhipu :: Text -> EffortContract
zhipu m
  | m == "glm-5.2" =
      EffortContract
        ["none", "minimal", "low", "medium", "high", "xhigh", "max"]
        "max" ["none", "minimal"] False "reasoning_effort"
  | m `elem` ["glm-5.3", "glm-5.3-flash"] =
      EffortContract ["low", "high", "max"] "max" [] True "reasoning_effort"
  -- A GLM model without a documented depth scale keeps the binary knob.
  | otherwise = binaryGlm

-- | GLM reached over a non-OpenAI wire: thinking is a binary thinking.type.
binaryGlm :: EffortContract
binaryGlm = EffortContract ["auto", "disabled", "enabled"] "auto" ["disabled"] False "thinking.type"

generic :: EffortContract
generic = EffortContract ["auto", "minimal", "low", "medium", "high"] "auto" [] False "reasoning_effort"

-- | Menu levels, with the probe's ladder taking precedence when it exists.
levelsFor :: [Text] -> Text -> Text -> Text -> [Text]
levelsFor probed base kind model
  | null probed = ecLevels (contractFor base kind model)
  | otherwise   = "auto" : probed
