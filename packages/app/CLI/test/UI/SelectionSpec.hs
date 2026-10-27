{-# LANGUAGE OverloadedStrings #-}

module UI.SelectionSpec (spec) where

import Test.Hspec
import UI.Selection

spec :: Spec
spec = do
  let lines0 = ["hello world", "second line", "third"]

  describe "normalizeSelection" $ do
    it "orders endpoints regardless of drag direction" $ do
      normalizeSelection (Selection (SelPos 2 0) (SelPos 1 3))
        `shouldBe` (SelPos 1 3, SelPos 2 0)

  describe "selectionIsEmpty" $ do
    it "treats a click without movement as empty" $
      selectionIsEmpty (Selection (SelPos 1 2) (SelPos 1 2)) `shouldBe` True
    it "is not empty after a drag" $
      selectionIsEmpty (Selection (SelPos 1 2) (SelPos 1 4)) `shouldBe` False

  describe "selectionText" $ do
    it "extracts a partial single row" $
      selectionText lines0 (Selection (SelPos 0 6) (SelPos 0 11))
        `shouldBe` "world"
    it "extracts across rows" $
      selectionText lines0 (Selection (SelPos 0 6) (SelPos 1 6))
        `shouldBe` "world\nsecond"
    it "clamps columns to the line length" $
      selectionText lines0 (Selection (SelPos 1 0) (SelPos 1 999))
        `shouldBe` "second line"
    it "returns empty text when the selection misses every line" $
      selectionText lines0 (Selection (SelPos 9 0) (SelPos 10 0)) `shouldBe` ""
    it "returns empty text without lines" $
      selectionText [] (Selection (SelPos 0 0) (SelPos 0 1)) `shouldBe` ""
