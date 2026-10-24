{-# LANGUAGE OverloadedStrings #-}

-- | Two wire guards that came out of real 400s.
--
--   * thinking mode requires @reasoning_content@ on every assistant turn — the
--     synthetic ones the host appends (a presentation card, "interrupted") used
--     to break the next request;
--   * a provider failure must not look like "the model said nothing".
module WireGuardsSpec (wireGuardsSpec) where

import Data.Aeson (Value (..))
import Data.Aeson.Key (fromText)
import Data.Text (Text)
import qualified Data.Aeson.KeyMap as KM
import qualified Data.Aeson as Aeson
import Test.Hspec

import API.Server (toolErrorContent)
import LLM.Adapter.Types
  (ChatMessage (..), ToolCall (..))
import LLM.Providers.DeepSeek (withReasoningEcho)

field :: Text -> Value -> Maybe Value
field k (Object o) = KM.lookup (fromText k) o
field _ _ = Nothing

withReasoning :: [Value] -> [Maybe Value]
withReasoning = map (field "reasoning_content")

wireGuardsSpec :: Spec
wireGuardsSpec = describe "wire guards" $ do
  describe "reasoning_content echo (thinking mode)" $ do
    let messages =
          [ ChatSystem "sys"
          , ChatUser "hi"
          , ChatAssistant "plain answer" []
          , ChatAssistantThought "with tools" [ToolCall "c1" "bash" "{}"] "I thought about it"
          , ChatAssistant "synthetic note" []
          ]

    it "adds the field to an assistant turn that lacks it" $ do
      let out = withReasoningEcho messages
      withReasoning (take 3 out) `shouldBe` [Nothing, Nothing, Just (String "")]

    it "keeps a real chain untouched" $ do
      let out = withReasoningEcho messages
      withReasoning (take 4 out) !! 3 `shouldBe` Just (String "I thought about it")

    it "never touches user or system turns" $ do
      let out = withReasoningEcho messages
      withReasoning (take 2 out) `shouldBe` [Nothing, Nothing]
      -- and every assistant turn ends up with the field
      length (filter (/= Nothing) (withReasoning out)) `shouldBe` 3

  describe "provider errors are content, not silence" $ do
    it "prefixes the error so a 4xx cannot look like an empty answer" $
      toolErrorContent (Just "HTTP 400: bad tool_calls") ""
        `shouldBe` "[provider error] HTTP 400: bad tool_calls"

    it "keeps content when there is no error" $
      toolErrorContent Nothing "hello" `shouldBe` "hello"

    it "does not drop partial content when an error is present" $
      toolErrorContent (Just "boom") "partial"
        `shouldBe` "[provider error] boom"
