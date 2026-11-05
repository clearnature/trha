{-# LANGUAGE OverloadedStrings #-}

module UI.TextWidthSpec (spec) where

import Brick.Widgets.Core (takeColumnsT)
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

  -- brick 的 takeColumnsT 从 submodule 导出后，这里固定它与 takeCells 的
  -- 实际差异。注意不是「brick 会切断组合字符」——safeWcwidth 对组合字符
  -- 返回 0，所以照样保留；真正的差异在 ZWJ emoji 序列。
  describe "brick takeColumnsT (submodule 导出，对照)" $ do
    it "truncates ASCII at the column budget" $
      takeColumnsT 3 "abcdef" `shouldBe` "abc"
    it "agrees with takeCells on CJK" $
      takeColumnsT 3 "中a中" `shouldBe` takeCells 3 "中a中"
    it "keeps combining marks (safeWcwidth = 0 means no cut)" $
      takeColumnsT 1 "e\x0301" `shouldBe` "e\x0301"
    it "differs from takeCells on ZWJ sequences" $ do
      let family = "\x1F468\x200D\x1F469\x200D\x1F467"
      -- takeCells：grapheme 粒度，完整保留整个 ZWJ 序列
      takeCells 2 family `shouldBe` family
      -- takeColumnsT：Char 粒度 + libc wcwidth（本机 emoji 宽 1），
      -- 会从中间切开。具体切在哪取决于平台 wcwidth，所以只断言「不等」。
      takeColumnsT 2 family `shouldSatisfy` (/= family)
