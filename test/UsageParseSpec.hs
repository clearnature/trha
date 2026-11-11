{-# LANGUAGE OverloadedStrings #-}

-- | Provider usage parsing.
--
-- The footer bills the cache split, so a wire that drops it turns every call
-- into a full-price prompt: the Responses and Anthropic parsers used to read
-- only @input_tokens@/@output_tokens@, which is why a live @deepseek-responses@
-- turn showed no @cached@ / @new@ line at all.
module UsageParseSpec (usageParseSpec) where

import Data.Aeson (Object (..), Value (..), decode)
import qualified Data.ByteString.Lazy as BL
import Test.Hspec

import API.ProviderRuntime
  ( cachedPromptTokens, usageFromAnthropic, usageFromResponses )
import LLM.Adapter.Types (Usage (..))

-- | A usage object decoded from the exact JSON a provider sends, so nested
-- shapes are exercised instead of hand-built maps.
usageObj :: BL.ByteString -> Object
usageObj raw = case decode raw of
  Just (Object o) -> o
  other -> error ("usageObj: expected an object, got " <> show other)

usageParseSpec :: Spec
usageParseSpec = describe "provider usage parsing" $ do
  describe "cachedPromptTokens" $ do
    it "reads OpenAI's nested input_tokens_details" $
      cachedPromptTokens
        (usageObj "{\"input_tokens\":100,\"input_tokens_details\":{\"cached_tokens\":80}}")
        `shouldBe` Just 80

    it "reads the prompt_tokens_details variant" $
      cachedPromptTokens
        (usageObj "{\"prompt_tokens\":100,\"prompt_tokens_details\":{\"cached_tokens\":70}}")
        `shouldBe` Just 70

    it "reads DeepSeek's flat prompt_cache_hit_tokens" $
      cachedPromptTokens
        (usageObj "{\"prompt_tokens\":100,\"prompt_cache_hit_tokens\":90}")
        `shouldBe` Just 90

    it "reports Nothing when the provider gives no split" $
      cachedPromptTokens (usageObj "{\"input_tokens\":100}") `shouldBe` Nothing

  describe "Responses wire" $ do
    it "keeps the cached subset out of the miss" $ do
      let u = usageFromResponses (Just 6334) (Just 504) (Just 6000)
      usagePromptTokens u `shouldBe` 6334
      usageCacheHitTokens u `shouldBe` 6000
      usageCacheMissTokens u `shouldBe` 334
      usageCompletionTokens u `shouldBe` 504

    it "leaves hit/miss at zero when no split is reported" $ do
      let u = usageFromResponses (Just 100) (Just 20) Nothing
      usageCacheHitTokens u `shouldBe` 0
      usageCacheMissTokens u `shouldBe` 0

    it "never bills a cached count larger than the prompt" $ do
      let u = usageFromResponses (Just 10) (Just 1) (Just 99)
      usageCacheHitTokens u `shouldBe` 10
      usageCacheMissTokens u `shouldBe` 0

  describe "Anthropic wire" $ do
    it "counts cache reads as hits and input+writes as the miss" $ do
      let u = usageFromAnthropic (Just 100) (Just 50) (Just 900) (Just 20)
      usagePromptTokens u `shouldBe` 1020
      usageCacheHitTokens u `shouldBe` 900
      usageCacheMissTokens u `shouldBe` 120

    it "leaves hit/miss at zero when neither cache field is present" $ do
      let u = usageFromAnthropic (Just 100) (Just 50) Nothing Nothing
      usageCacheHitTokens u `shouldBe` 0
      usageCacheMissTokens u `shouldBe` 0
