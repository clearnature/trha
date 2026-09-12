{-# LANGUAGE OverloadedStrings #-}

module Core.SessionSummarySpec (spec) where

import Test.Hspec
import Core.SessionSummary
import Data.Aeson (Value(..), object, (.=))
import Data.Aeson.Types (Pair)
import Data.Text (Text)
import qualified Data.Text as T

-- Helpers to build transcript event lines matching Core.Transcript's jsonl.
sessionEvent :: Text -> [Pair] -> Value
sessionEvent ev extra = object (["event" .= ev] <> extra)

userMsg :: Text -> Text -> Value
userMsg ts content = sessionEvent "user" ["ts" .= ts, "session" .= ("s1" :: Text), "content" .= content]

spec :: Spec
spec = do
  describe "sessionSummaryOf" $ do
    it "projects an empty transcript to defaults" $ do
      sessionSummaryOf "s1" []
        `shouldBe` SessionSummary { ssId = "s1", ssTitle = defaultTitle "s1"
                                  , ssTurns = 0, ssModel = Nothing, ssLastTs = Nothing }

    it "extracts model from the session event" $ do
      let ev = sessionEvent "session" ["ts" .= ("2026-09-05T00:00:00Z" :: Text), "model" .= ("deepseek-chat" :: Text)]
      ssModel (sessionSummaryOf "s1" [ev]) `shouldBe` Just "deepseek-chat"

    it "counts user turns" $ do
      let evs = [ userMsg "t1" "hello", userMsg "t2" "again" ]
      ssTurns (sessionSummaryOf "s1" evs) `shouldBe` 2

    it "titles from the first user message (truncated)" $ do
      let long = T.replicate 100 "x"
      ssTitle (sessionSummaryOf "s1" [userMsg "t1" long])
        `shouldBe` summaryTitle long

    it "tracks the last event timestamp" $ do
      let evs = [ userMsg "t1" "hello", sessionEvent "assistant" ["ts" .= ("t9" :: Text)] ]
      ssLastTs (sessionSummaryOf "s1" evs) `shouldBe` Just "t9"

    it "ignores unknown event kinds" $ do
      let evs = [ sessionEvent "mystery" ["ts" .= ("t1" :: Text), "content" .= ("zzz" :: Text)]
                , userMsg "t2" "hi" ]
      ssTitle (sessionSummaryOf "s1" evs) `shouldBe` "hi"
      ssTurns (sessionSummaryOf "s1" evs) `shouldBe` 1

    it "keeps Chinese titles intact (short)" $ do
      ssTitle (sessionSummaryOf "s1" [userMsg "t1" "你好世界"])
        `shouldBe` "你好世界"

  describe "summaryTitle" $ do
    it "truncates long titles with an ellipsis" $ do
      summaryTitle (T.replicate 60 "y") `shouldBe` T.replicate 47 "y" <> "…"

    it "leaves short titles untouched" $ do
      summaryTitle "short" `shouldBe` "short"
