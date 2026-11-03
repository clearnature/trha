{-# LANGUAGE OverloadedStrings #-}

module UI.PasteFoldSpec (spec) where

import Test.Hspec
import qualified Data.Text as T
import UI.PasteFold

spec :: Spec
spec = do
  describe "isLongPaste" $ do
    it "keeps short text inline" $
      isLongPaste "hello" `shouldBe` False

    it "keeps a four-line snippet inline" $
      isLongPaste "a\nb\nc\nd" `shouldBe` False

    it "folds at five lines" $
      isLongPaste "a\nb\nc\nd\ne" `shouldBe` True

    it "folds text past the character cap" $
      isLongPaste (T.replicate 1001 "x") `shouldBe` True

    it "keeps text at the character cap inline" $
      isLongPaste (T.replicate 1000 "x") `shouldBe` False

  describe "pasteLabel" $ do
    it "names the paste and its line count" $
      pasteLabel 1 20 `shouldBe` "[Pasted text #1 · 20 lines]"

    it "keeps the index for the second paste" $
      pasteLabel 2 3 `shouldBe` "[Pasted text #2 · 3 lines]"

  describe "expandPastes" $ do
    it "replaces a folded placeholder with the original text" $
      expandPastes [("[Pasted text #1 · 2 lines]", "a\nb")]
        ("看这段：\n[Pasted text #1 · 2 lines]\n谢谢")
        `shouldBe` ("看这段：\na\nb\n谢谢")

    it "expands several placeholders" $
      expandPastes
        [ ("[Pasted text #1 · 2 lines]", "a\nb")
        , ("[Pasted text #2 · 2 lines]", "c\nd") ]
        "[Pasted text #1 · 2 lines] 与 [Pasted text #2 · 2 lines]"
        `shouldBe` "a\nb 与 c\nd"

    it "leaves text alone when nothing is folded" $
      expandPastes [] "普通文本" `shouldBe` "普通文本"
