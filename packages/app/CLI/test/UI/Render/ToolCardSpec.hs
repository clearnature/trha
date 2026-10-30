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

  describe "toggleFold" $ do
    it "flips both states" $ do
      toggleFold FoldCollapsed `shouldBe` FoldExpanded
      toggleFold FoldExpanded `shouldBe` FoldCollapsed

  describe "toolCardCollapsed" $ do
    it "is a single summary line with inline status" $ do
      toolCardCollapsed (ToolCard "bash" ["ls -la"] (Just ToolSucceeded) (Just 120) ["out"] "" Nothing)
        `shouldBe` ["[tool] bash ✓ 120ms ls -la"]

    it "marks a running card without a terminal event" $ do
      toolCardCollapsed (ToolCard "bash" [] Nothing Nothing [] "" Nothing)
        `shouldBe` ["[tool] bash (running…)"]

    it "truncates over-long summaries" $ do
      let long = T.replicate 100 "x"
      map T.length (toolCardCollapsed (ToolCard "bash" [long] (Just ToolSucceeded) Nothing [] "" Nothing))
        `shouldSatisfy` all (<= cardWidth)

    it "flattens newlines in inline arguments" $ do
      toolCardCollapsed (ToolCard "bash" ["a\nb"] (Just ToolSucceeded) Nothing [] "" Nothing)
        `shouldBe` ["[tool] bash ✓ a b"]

  describe "toolCardExpanded" $ do
    it "shows title, arguments, output preview and status" $ do
      toolCardExpanded (ToolCard "bash" ["ls"] (Just ToolSucceeded) (Just 5) ["a", "b"] "" Nothing)
        `shouldBe` [ "[tool] bash", "  ls", "  │ a", "  │ b", "  ✓ 5ms" ]

    it "omits the status line for unreported cards (replay)" $ do
      toolCardExpanded (ToolCard "read_file" ["x"] Nothing Nothing [] "" Nothing)
        `shouldBe` [ "[tool] read_file", "  x" ]

    it "width-truncates over-long output lines" $ do
      let long = T.replicate 100 "y"
      let [_, _, line] = toolCardExpanded (ToolCard "bash" [] (Just ToolSucceeded) Nothing [long] "" Nothing)
      T.length line `shouldSatisfy` (<= cardWidth)

  describe "toolCardView" $ do
    it "dispatches by fold state" $ do
      let card = ToolCard "bash" [] (Just ToolSucceeded) Nothing [] "" Nothing
      toolCardView FoldCollapsed card `shouldBe` toolCardCollapsed card
      toolCardView FoldExpanded card `shouldBe` toolCardExpanded card
