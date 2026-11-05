{-# LANGUAGE OverloadedStrings #-}

module UI.TextWidthSpec (spec) where

import Test.Hspec
import UI.TextWidth

spec :: Spec
spec = do
  describe "charCellWidth" $ do
    it "counts ASCII as one cell" $
      charCellWidth 'a' `shouldBe` 1
    it "counts CJK as two cells" $
      charCellWidth '中' `shouldBe` 2
    it "counts an emoji as two cells" $
      charCellWidth '😀' `shouldBe` 2
    it "gives combining marks zero width" $
      charCellWidth '\x0301' `shouldBe` 0
    it "gives controls zero width" $
      charCellWidth '\ESC' `shouldBe` 0

  describe "textWidth" $
    it "sums cells for mixed text" $
      textWidth "中a😀" `shouldBe` 5

  describe "takeCells" $ do
    it "truncates at a cell boundary" $
      takeCells 3 "中a中" `shouldBe` "中a"
    it "returns empty for a zero budget" $
      takeCells 0 "abc" `shouldBe` ""

  describe "grapheme clusters (Reasonix uniseg / qwen string-width contract)" $ do
    it "counts a ZWJ emoji sequence as two cells" $
      textWidth "\x1F468\x200D\x1F469\x200D\x1F467" `shouldBe` 2
    it "counts a regional-indicator flag as two cells" $
      textWidth "\x1F1E8\x1F1F3" `shouldBe` 2
    it "treats a combining accent as part of its base" $
      textWidth "e\x0301" `shouldBe` 1
    it "does not split a cluster when truncating" $
      takeCells 2 ("\x1F468\x200D\x1F469\x200D\x1F467" <> "x")
        `shouldBe` "\x1F468\x200D\x1F469\x200D\x1F467"
