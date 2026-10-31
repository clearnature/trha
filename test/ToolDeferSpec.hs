{-# LANGUAGE OverloadedStrings #-}

-- | The Anthropic wire shape of deferred tool loading.
--
-- These assertions cover the last hop that could not be checked from the
-- TypeScript side: whether a `deferLoading` flag actually becomes
-- `defer_loading` in the request body, and whether the beta header is only
-- added when something is deferred.
module ToolDeferSpec (spec) where

import API.ProviderRuntime (anthropicHeaders, anthropicTools, toolChangesBeta)
import Data.Aeson (Value (..))
import qualified Data.Aeson.KeyMap as KM
import LLM.Adapter.Types (ToolSpec (..))
import Network.HTTP.Types.Header (Header)
import Test.Hspec

-- | A minimal tool with an empty schema and the flag under test.
tool :: Bool -> ToolSpec
tool deferred = ToolSpec "probe" "probe" (Object mempty) deferred

deferMarker :: Value -> Maybe Value
deferMarker (Object o) = KM.lookup "defer_loading" o
deferMarker _ = Nothing

hasBeta :: [Header] -> Bool
hasBeta hs = any (\(name, _) -> name == "anthropic-beta") hs

spec :: Spec
spec = describe "deferred tool loading (Anthropic wire)" $ do
  it "marks a deferred tool with defer_loading" $ do
    -- Needs a second, eager tool: with only deferred entries the list would be
    -- "all deferred", which the provider rejects (covered by the next case).
    case anthropicTools [tool True, tool False] of
      [deferred, eager] -> do
        deferMarker deferred `shouldBe` Just (Bool True)
        deferMarker eager `shouldBe` Nothing
      other -> expectationFailure ("expected two tools, got " <> show (length other))

  it "un-defers a lone deferred tool so the request stays legal" $
    -- "All tools cannot be deferred" also means a single deferred tool: the
    -- fallback drops the flag rather than sending a request the provider refuses.
    case anthropicTools [tool True] of
      [v] -> deferMarker v `shouldBe` Nothing
      other -> expectationFailure ("expected one tool, got " <> show (length other))

  it "leaves an eager tool unmarked" $ do
    case anthropicTools [tool False] of
      [v] -> deferMarker v `shouldBe` Nothing
      other -> expectationFailure ("expected one tool, got " <> show (length other))

  it "never sends a fully deferred list" $ do
    -- DeepSeek rejects "all tools deferred": at least one must stay eager.
    case anthropicTools [tool True, tool True] of
      [first, second] -> do
        deferMarker first `shouldBe` Nothing
        deferMarker second `shouldBe` Just (Bool True)
      other -> expectationFailure ("expected two tools, got " <> show (length other))

  it "adds the beta header only when something is deferred" $ do
    hasBeta (anthropicHeaders "key" [] [tool True]) `shouldBe` True
    hasBeta (anthropicHeaders "key" [] [tool False]) `shouldBe` False
    hasBeta (anthropicHeaders "key" [] []) `shouldBe` False

  it "uses the beta value DSH uses" $
    -- Mirrors MESSAGES_TOOL_CHANGES_BETA in dsh's llm-deepseek.
    toolChangesBeta `shouldBe` "mid-conversation-tool-changes-2026-07-01"
