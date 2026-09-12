{-# LANGUAGE OverloadedStrings #-}

module UI.Render.ToolCardSpec (spec) where

import Test.Hspec
import UI.Render.ToolCard
import qualified Data.Text as T

spec :: Spec
spec = do
  describe "toolTitle" $ do
    it "formats a plain tool name" $ do
      toolTitle "read_file" `shouldBe` "[tool] read_file"

    it "keeps namespaced tool names intact" $ do
      toolTitle "fs.read_file" `shouldBe` "[tool] fs.read_file"

  describe "toolArgLines" $ do
    it "returns no lines for no arguments" $ do
      toolArgLines [] `shouldBe` []

    it "renders one line per argument" $ do
      toolArgLines ["a.txt", "1"]
        `shouldBe` ["  a.txt", "  1"]

    it "truncates over-long arguments" $ do
      let long = T.replicate 100 "x"
      map T.length (toolArgLines [long]) `shouldSatisfy` all (<= cardWidth + 1)

    it "keeps Chinese argument text intact when short" $ do
      toolArgLines ["你好世界"] `shouldBe` ["  你好世界"]

  describe "toolCardLines" $ do
    it "combines title and arguments" $ do
      toolCardLines "write_file" ["out.md", "42"]
        `shouldBe` [ "[tool] write_file", "  out.md", "  42" ]

    it "renders a bare call (no args) as title only" $ do
      toolCardLines "listModels" [] `shouldBe` ["[tool] listModels"]

  describe "toolStatusLine / toolCardWithStatus" $ do
    it "renders a succeeded footer with duration" $ do
      toolStatusLine ToolSucceeded (Just 12) `shouldBe` "  ✓ 12ms"

    it "renders a running footer" $ do
      toolStatusLine ToolRunning Nothing `shouldBe` "  running…"

    it "renders a failed footer with the error" $ do
      toolStatusLine (ToolFailed "exit 1") Nothing `shouldBe` "  ✗ exit 1"

    it "appends the status footer to a card" $ do
      toolCardWithStatus "bash" ["ls"] ToolSucceeded (Just 5)
        `shouldBe` ["[tool] bash", "  ls", "  ✓ 5ms"]
