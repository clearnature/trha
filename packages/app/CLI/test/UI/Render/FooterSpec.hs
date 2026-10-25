{-# LANGUAGE OverloadedStrings #-}

module UI.Render.FooterSpec (spec) where

import Test.Hspec
import Core.Types (Usage(..))
import UI.Render.Footer
import UI.I18n (Lang(..))
import qualified Data.Text as T

spec :: Spec
spec = do
  describe "footerSegments" $ do
    it "starts with the model and ends with the key hints" $ do
      let segs = footerSegments "deepseek-chat" (Just "s1") "Ready" Nothing
      head segs `shouldBe` "Model: deepseek-chat"
      last segs `shouldBe` "PgUp/PgDn scroll · g/G top/bottom · Ctrl+O expand tool output · Ctrl+Q quit"

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
      takeWhile (/= "PgUp/PgDn scroll · g/G top/bottom · Ctrl+O expand tool output · Ctrl+Q quit") segs
        `shouldSatisfy` ("last: 1 tokens" `elem`)
  describe "parseMetrics / footerMetrics" $ do
    it "keeps only supported keys, in order, unique" $ do
      parseMetrics "session,tokens,context,bogus,git" `shouldBe` ["session", "tokens", "context", "git"]
      parseMetrics defaultMetrics `shouldBe` ["model", "usage", "context", "session"]
    it "renders a localised metric segment set" $ do
      let live = FooterLive "m" (Just "s1") "Ready" (Just 42) 100 Nothing Nothing
          segs = footerMetrics Zh ["model", "context", "session"] live [("git", "main")]
      segs `shouldBe` ["模型：m", "上下文：100 字符", "会话：s1"]
    it "renders the usage segment with in/out/total and occupancy" $ do
      let live = FooterLive "m" Nothing "Ready" Nothing 100
                    (Just (Usage 200 50 250)) (Just 1000)
          segs = footerMetrics Zh ["usage"] live []
      segs `shouldBe` ["输入 200 · 输出 50 · 累计 250 · 占用 20%"]

    it "omits occupancy without a context size" $ do
      let live = FooterLive "m" Nothing "Ready" Nothing 0
                    (Just (Usage 200 50 250)) Nothing
      footerMetrics En ["usage"] live [] `shouldBe` ["in 200 · out 50 · total 250"]
    it "falls back to dash for a missing static value" $ do
      let live = FooterLive "m" Nothing "Ready" Nothing 0 Nothing Nothing
      footerMetrics En ["git", "tokens"] live [] `shouldBe` ["Git branch: —", "Tokens: —"]
