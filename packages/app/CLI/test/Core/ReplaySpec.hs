{-# LANGUAGE OverloadedStrings #-}

module Core.ReplaySpec (spec) where

import Test.Hspec
import Core.Replay
import Data.Aeson (Value(..), object, (.=))
import Data.Aeson.Types (Pair)
import Data.Text (Text)

sessionEvent :: Text -> [Pair] -> Value
sessionEvent ev extra = object (["event" .= ev] <> extra)

userMsg :: Text -> Text -> Value
userMsg ts content = sessionEvent "user" ["ts" .= ts, "content" .= content]

assistantMsg :: Text -> Text -> Value
assistantMsg ts content = sessionEvent "assistant" ["ts" .= ts, "content" .= content]

spec :: Spec
spec = do
  describe "renderReplay" $ do
    it "projects user and assistant events in order" $ do
      renderReplay [userMsg "t1" "hello", assistantMsg "t2" "hi there"]
        `shouldBe` [ ReplayBlock "user" "hello" (Just "t1") Nothing
                   , ReplayBlock "assistant" "hi there" (Just "t2") Nothing ]

    it "skips the session-created event" $ do
      let created = sessionEvent "session" ["model" .= ("m" :: Text)]
      renderReplay [created, userMsg "t1" "hello"]
        `shouldBe` [ ReplayBlock "user" "hello" (Just "t1") Nothing ]

    it "projects tool events with name and args" $ do
      let tool = sessionEvent "tool"
            [ "ts" .= ("t1" :: Text), "tool" .= ("bash" :: Text)
            , "args" .= (["ls", "-la"] :: [Text]) ]
      renderReplay [tool]
        `shouldBe` [ ReplayBlock "tool" "" (Just "t1") (Just ("bash", ["ls", "-la"])) ]

    it "projects done events into a system usage line" $ do
      let done = sessionEvent "done"
            [ "ts" .= ("t1" :: Text)
            , "usage" .= object ["usageTotalTokens" .= (123 :: Int)] ]
      renderReplay [done]
        `shouldBe` [ ReplayBlock "system" "✓ 123 tokens" (Just "t1") Nothing ]

    it "projects error events" $ do
      let err = sessionEvent "error" [ "ts" .= ("t1" :: Text), "content" .= ("boom" :: Text) ]
      renderReplay [err]
        `shouldBe` [ ReplayBlock "error" "boom" (Just "t1") Nothing ]

    it "drops tool events without args gracefully" $ do
      let tool = sessionEvent "tool" [ "tool" .= ("x" :: Text) ]
      renderReplay [tool]
        `shouldBe` [ ReplayBlock "tool" "" Nothing (Just ("x", [])) ]

    it "skips unknown and malformed events" $ do
      let unknown = sessionEvent "mystery" [ "content" .= ("z" :: Text) ]
      renderReplay [unknown, userMsg "t1" "hi"]
        `shouldBe` [ ReplayBlock "user" "hi" (Just "t1") Nothing ]

    it "handles an empty transcript" $ do
      renderReplay [] `shouldBe` []

  describe "renderReplayText" $ do
    it "labels roles and indents content" $ do
      renderReplayText (renderReplay [userMsg "t1" "hello", assistantMsg "t2" "hi"])
        `shouldBe` "[user] t1\n  hello\n\n[assistant] t2\n  hi"

    it "renders tool blocks as tool lines" $ do
      let tool = sessionEvent "tool"
            [ "ts" .= ("t1" :: Text), "tool" .= ("bash" :: Text)
            , "args" .= (["ls"] :: [Text]) ]
      renderReplayText (renderReplay [tool])
        `shouldBe` "[tool] t1\n  [tool] bash ls"
