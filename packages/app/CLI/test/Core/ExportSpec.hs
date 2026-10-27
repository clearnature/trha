{-# LANGUAGE OverloadedStrings #-}

module Core.ExportSpec (spec) where

import Core.Export
import Data.Aeson (Value(..), decodeStrict, object, (.=))
import qualified Data.Aeson.KeyMap as KM
import Data.Foldable (toList)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Test.Hspec

events :: [Value]
events =
  [ object [ "v" .= (1 :: Int), "event" .= ("user" :: T.Text), "content" .= ("hello" :: T.Text), "ts" .= ("12:00:01" :: T.Text) ]
  , object [ "v" .= (1 :: Int), "event" .= ("tool" :: T.Text), "tool" .= ("bash" :: T.Text), "args" .= (["command=ls"] :: [T.Text]), "ts" .= ("12:00:02" :: T.Text) ]
  , object [ "v" .= (1 :: Int), "event" .= ("assistant" :: T.Text), "content" .= ("hi there" :: T.Text), "ts" .= ("12:00:03" :: T.Text) ]
  ]

spec :: Spec
spec = do
  describe "exportMarkdown" $ do
    it "puts a header with the session id and export time" $ do
      let md = exportMarkdown "sess-1" "2026-10-25 23:00:00" events
      T.lines md `shouldSatisfy` \ls ->
        ("# Session sess-1" `elem` ls) && ("_exported 2026-10-25 23:00:00_" `elem` ls)

    it "renders one section per replay block" $ do
      let md = exportMarkdown "s" "t" events
      md `shouldSatisfy` T.isInfixOf "## user · 12:00:01"
      md `shouldSatisfy` T.isInfixOf "hello"
      md `shouldSatisfy` T.isInfixOf "## assistant · 12:00:03"
      md `shouldSatisfy` T.isInfixOf "hi there"

    it "renders tool calls as a fenced summary" $ do
      let md = exportMarkdown "s" "t" events
      md `shouldSatisfy` T.isInfixOf "## tool · 12:00:02"
      md `shouldSatisfy` T.isInfixOf "[bash] command=ls"

  describe "exportJson" $ do
    it "keeps the raw events in an envelope" $ do
      let out = exportJson "sess-1" "2026-10-25" events
      case decodeStrict (TE.encodeUtf8 out) of
        Just (Object o) -> do
          KM.lookup "sessionId" o `shouldBe` Just (String "sess-1")
          case KM.lookup "events" o of
            Just (Array evs) -> length (toList evs) `shouldBe` 3
            other -> expectationFailure ("events: " <> show other)
        other -> expectationFailure ("decoded: " <> show other)

  describe "defaultExportName" $ do
    it "replaces path-hostile characters in the stamp" $
      defaultExportName "sess-1" "2026-10-25 23:00:00" "md"
        `shouldBe` "sess-1-2026-10-25-23-00-00.md"

  describe "UTC marker" $ do
    it "marks exported timestamps as UTC" $ do
      let md = exportMarkdown "s" "t" []
      md `shouldSatisfy` T.isInfixOf "Times are UTC"
