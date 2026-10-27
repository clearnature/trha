{-# LANGUAGE OverloadedStrings #-}

-- | Contract test for docs/contracts/session-truth.md: the kernel event log
-- must rebuild the same model-visible message sequence the scheduler persists.
--
-- The scheduler half is `packages/scheduler/test/session-truth.test.ts`; both
-- use the same fixture and the same rules.
module SessionTruthSpec (sessionTruthSpec) where

import Data.Aeson (object, (.=))
import Test.Hspec

import Core.Agent.Types (AgentState (..))
import Core.Session.Types
import Core.Session.Projection

sessionTruthSpec :: Spec
sessionTruthSpec = describe "Session truth (kernel log -> messages)" $ do
  it "rebuilds user / assistant / tool messages in order" $ do
    let events =
          [ UserMessage "hello"
          , AssistantMessage "hi"
          , ToolCall "bash" (object ["cmd" .= ("ls" :: String)])
          , ToolResult "bash" (object ["out" .= ("a" :: String)])
          ]
        expected =
          [ SessionMessage "user" "hello" Nothing Nothing
          , SessionMessage "assistant" "hi" Nothing Nothing
          , SessionMessage "assistant" ""
              (Just [object ["name" .= ("bash" :: String), "arguments" .= object ["cmd" .= ("ls" :: String)]]])
              Nothing
          , SessionMessage "tool" "{\"out\":\"a\"}" Nothing (Just "bash")
          ]
    eventsToMessages events `shouldBe` expected

  it "skips state events (the FSM is a fold over the same log, not a message)" $
    eventsToMessages [UserMessage "hi", AgentStateChanged Idle]
      `shouldBe` [SessionMessage "user" "hi" Nothing Nothing]

  it "is stable when replayed twice (event log is the only input)" $
    let events = [UserMessage "a", AssistantMessage "b"]
    in eventsToMessages events `shouldBe` eventsToMessages events
