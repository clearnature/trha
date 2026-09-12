{-# LANGUAGE OverloadedStrings #-}

module UI.Render.FooterSpec (spec) where

import Test.Hspec
import UI.Render.Footer
import UI.I18n (Lang(..))
import qualified Data.Text as T

spec :: Spec
spec = do
  describe "footerSegments" $ do
    it "starts with the model and ends with the key hints" $ do
      let segs = footerSegments "deepseek-chat" (Just "s1") "Ready" Nothing
      head segs `shouldBe` "Model: deepseek-chat"
      last segs `shouldBe` "PgUp/PgDn scroll · g/G top/bottom · Ctrl+Q quit"

    it "shows the session when present" $ do
      let segs = footerSegments "m" (Just "abc") "Ready" Nothing
      "Session: abc" `elem` segs

    it "shows 'none' when no session is active" $ do
      let segs = footerSegments "m" Nothing "Ready" Nothing
      "Session: none" `elem` segs

    it "omits the usage segment when unknown" $ do
      let segs = footerSegments "m" Nothing "Ready" Nothing
      filter ("last:" `T.isPrefixOf`) segs `shouldBe` []

    it "includes the usage segment when available" $ do
      let segs = footerSegments "m" Nothing "Ready" (Just 1234)
      filter ("last:" `T.isPrefixOf`) segs `shouldBe` ["last: 1234 tokens"]

    it "places usage before the hints" $ do
      let segs = footerSegments "m" Nothing "Ready" (Just 1)
      takeWhile (/= "PgUp/PgDn scroll · g/G top/bottom · Ctrl+Q quit") segs
        `shouldSatisfy` ("last: 1 tokens" `elem`)
  describe "parseMetrics / footerMetrics" $ do
    it "keeps only supported keys, in order, unique" $ do
      parseMetrics "session,tokens,context,bogus,git" `shouldBe` ["session", "tokens", "context", "git"]
      parseMetrics defaultMetrics `shouldBe` ["model", "git", "context", "session"]
    it "renders a localised metric segment set" $ do
      let live = FooterLive "m" (Just "s1") "Ready" (Just 42) 100
          segs = footerMetrics Zh ["model", "context", "session"] live [("git", "main")]
      segs `shouldBe` ["模型：m", "上下文：100 字符", "会话：s1"]
    it "falls back to dash for a missing static value" $ do
      let live = FooterLive "m" Nothing "Ready" Nothing 0
      footerMetrics En ["git", "tokens"] live [] `shouldBe` ["Git branch: —", "Tokens: —"]
