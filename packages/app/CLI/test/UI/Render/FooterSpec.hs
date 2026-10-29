{-# LANGUAGE OverloadedStrings #-}

module UI.Render.FooterSpec (spec) where

import Test.Hspec
import Core.Types (Usage(..), mkUsage)
import UI.Render.Footer
import UI.I18n (Lang(..))
import UI.TextWidth (textWidth)
import qualified Data.Text as T

spec :: Spec
spec = do
  describe "footerSegments" $ do
    it "starts with the model and ends with the key hints" $ do
      let segs = footerSegments "deepseek-chat" (Just "s1") "Ready" Nothing
      head segs `shouldBe` "Model: deepseek-chat"
      last segs `shouldBe` "Shift+Tab read-only/ask/auto/YOLO/plan · Ctrl+Y YOLO · Ctrl+O expand tool output · Ctrl+Q quit · Ctrl+Alt+Q stop services · Ctrl+C twice"

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
      takeWhile (/= "Shift+Tab read-only/ask/auto/YOLO/plan · Ctrl+Y YOLO · Ctrl+O expand tool output · Ctrl+Q quit · Ctrl+Alt+Q stop services") segs
        `shouldSatisfy` ("last: 1 tokens" `elem`)
  describe "parseMetrics / footerMetrics" $ do
    it "keeps only supported keys, in order, unique" $ do
      parseMetrics "session,tokens,context,bogus,git" `shouldBe` ["session", "tokens", "context", "git"]
      parseMetrics defaultMetrics `shouldBe` ["model", "mode", "cache", "ctx", "compact", "session"]
    it "renders a localised metric segment set" $ do
      let live = FooterLive "m" (Just "s1") "Ready" (Just 42) 100 Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing
          segs = footerMetrics Zh ["model", "context", "session"] live [("git", "main")]
      segs `shouldBe` ["模型：m", "上下文：100 字符", "会话：s1"]
    it "renders the usage segment with in/out/total and occupancy" $ do
      let live = FooterLive "m" Nothing "Ready" Nothing 100
                    (Just (mkUsage 200 50 250)) (Just 1000)
                    Nothing Nothing Nothing Nothing Nothing Nothing
          segs = footerMetrics Zh ["usage"] live []
      segs `shouldBe` ["输入 200 · 输出 50 · 累计 250 · 占用 20%"]

    it "omits occupancy without a context size" $ do
      let live = FooterLive "m" Nothing "Ready" Nothing 0
                    (Just (mkUsage 200 50 250)) Nothing
                    Nothing Nothing Nothing Nothing Nothing Nothing
      footerMetrics En ["usage"] live [] `shouldBe` ["in 200 · out 50 · total 250"]
    it "falls back to dash for a missing static value" $ do
      let live = FooterLive "m" Nothing "Ready" Nothing 0 Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing
      footerMetrics En ["git", "tokens"] live [] `shouldBe` ["Git branch: —", "Tokens: —"]

    it "renders the Reasonix status trio (cache / context / compact)" $ do
      let live = FooterLive "m" Nothing "Ready" Nothing 0 Nothing (Just 1000000)
                    (Just "Auto")
                    (Just (9993, 7)) (Just (99500, 500))
                    (Just 450100) (Just 35) Nothing
      footerMetrics En ["mode", "cache", "ctx", "compact"] live []
        `shouldBe` [ "Mode: Auto"
                   , "cache turn hit 99.93% · session 99.50%"
                   , "context 450.1K (45%)"
                   , "compact 35%"
                   ]
      footerMetrics Zh ["mode", "cache", "ctx", "compact"] live []
        `shouldBe` [ "模式：Auto"
                   , "缓存 本次命中 99.93% · 会话累计 99.50%"
                   , "上下文 450.1K (45%)"
                   , "压缩 35%"
                   ]

    it "omits cache/context/compact before any usage arrives" $ do
      let live = FooterLive "m" Nothing "Ready" Nothing 0 Nothing Nothing
                    Nothing Nothing Nothing Nothing Nothing Nothing
      footerMetrics En ["cache", "ctx", "compact"] live [] `shouldBe` ["", "", ""]

  describe "branchFromHead" $ do
    it "reads the branch name from .git/HEAD" $ do
      branchFromHead "ref: refs/heads/main\n" `shouldBe` Just "main"
      branchFromHead "ref: refs/heads/feature/lsp" `shouldBe` Just "lsp"
    it "returns Nothing for a detached HEAD" $
      branchFromHead "0123456789abcdef0123456789abcdef01234567" `shouldBe` Nothing

  describe "statusFitsOneRow" $ do
    -- The real 120-column overflow: git summary + metrics measured 129 cells,
    -- so hBox silently clipped the right end (balance / cost / peak).
    let git = "trha@main  +6650 -834  ?119"
        stats = "缓存 本次命中 98.78% · 会话累计 92.70%  上下文 15.9K (1%)  压缩 79%  余额 ¥30.77  费用 ≈¥0.0139 · 低峰"
    it "rejects the git + metrics pair on a 120-column terminal" $
      statusFitsOneRow 118 git stats `shouldBe` False
    it "accepts the same pair when the terminal is wide enough" $
      statusFitsOneRow 160 git stats `shouldBe` True
    it "measures wide (CJK) characters as two cells" $ do
      -- "上下文" is 3 CJK characters = 6 cells, not 3.
      statusFitsOneRow 40 "abc" "上下文" `shouldBe` True
      statusFitsOneRow 10 "abcdefgh" "上下文" `shouldBe` False
    it "always fits when one side is empty" $ do
      statusFitsOneRow 1 "" stats `shouldBe` True
      statusFitsOneRow 1 git "" `shouldBe` True

  describe "wrapStatusLine" $ do
    let stats = "缓存 本次命中 98.78% · 会话累计 92.70%  上下文 15.9K (1%)  压缩 79%  余额 ¥30.77  费用 ≈¥0.0139 · 低峰"
    it "keeps a row that fits on one line" $
      wrapStatusLine 118 stats `shouldBe` [stats]
    it "splits a 98-cell row into rows that really fit" $ do
      let rows = wrapStatusLine 90 stats
      length rows `shouldSatisfy` (>= 2)
      all (\r -> textWidth r <= 90) rows `shouldBe` True
      -- nothing is dropped, only the segment separators are consumed
      T.filter (/= ' ') (T.concat rows) `shouldBe` T.filter (/= ' ') stats
    it "wraps down to a narrow terminal without splitting clusters" $ do
      let rows = wrapStatusLine 20 stats
      all (\r -> textWidth r <= 20) rows `shouldBe` True
      T.filter (/= ' ') (T.concat rows) `shouldBe` T.filter (/= ' ') stats
    it "is empty for an empty row" $
      wrapStatusLine 80 "" `shouldBe` []
    it "still makes progress when one glyph is wider than the budget" $ do
      -- a CJK glyph is 2 cells; a 1-cell budget must emit it alone, not hang
      let rows = wrapStatusLine 1 "上下文"
      rows `shouldBe` ["上", "下", "文"]
