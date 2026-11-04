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

  -- 消息级选区判定（从 UI.Brick 迁入的 inSel 的纯核）。
  describe "inSelRange" $ do
    it "无选区时任何 id 都不命中" $
      inSelRange Nothing Nothing 3 `shouldBe` False

    it "只设锚点、光标未设时，选区就是锚点本身" $ do
      inSelRange (Just 5) Nothing 5 `shouldBe` True
      inSelRange (Just 5) Nothing 4 `shouldBe` False
      inSelRange (Just 5) Nothing 6 `shouldBe` False

    it "正序拖选包含两个端点" $ do
      inSelRange (Just 2) (Just 5) 2 `shouldBe` True
      inSelRange (Just 2) (Just 5) 4 `shouldBe` True
      inSelRange (Just 2) (Just 5) 5 `shouldBe` True

    it "逆序拖选（向上拖）同样成立" $ do
      inSelRange (Just 7) (Just 3) 3 `shouldBe` True
      inSelRange (Just 7) (Just 3) 5 `shouldBe` True
      inSelRange (Just 7) (Just 3) 7 `shouldBe` True

    it "区间外不命中" $ do
      inSelRange (Just 2) (Just 5) 1 `shouldBe` False
      inSelRange (Just 2) (Just 5) 6 `shouldBe` False
      inSelRange (Just 7) (Just 3) 2 `shouldBe` False
      inSelRange (Just 7) (Just 3) 8 `shouldBe` False

    it "单条消息的选区" $
      inSelRange (Just 9) (Just 9) 9 `shouldBe` True
