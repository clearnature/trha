{-# LANGUAGE OverloadedStrings #-}

module UI.Render.DiffSpec (spec) where

import Test.Hspec
import UI.Render.Diff

spec :: Spec
spec = do
  describe "diffClass" $ do
    it "classifies added lines" $ do
      diffClass "+import Data.List" `shouldBe` CAdd
      diffClass "+" `shouldBe` CAdd

    it "classifies removed lines" $ do
      diffClass "-old line" `shouldBe` CDel

    it "classifies hunk headers" $ do
      diffClass "@@ -1,3 +1,4 @@" `shouldBe` CHunk

    it "classifies file metadata" $ do
      diffClass "--- a/foo.ts" `shouldBe` CMeta
      diffClass "+++ b/foo.ts" `shouldBe` CMeta
      diffClass "diff --git a/foo.ts b/foo.ts" `shouldBe` CMeta
      diffClass "index 1234..5678 100644" `shouldBe` CMeta

    it "classifies context as plain" $ do
      diffClass " unchanged" `shouldBe` CPlain
      diffClass "@@not a hunk" `shouldBe` CPlain

  describe "parseDiffLines" $ do
    it "classifies a unified diff block" $ do
      parseDiffLines
        [ "diff --git a/x.ts b/x.ts"
        , "--- a/x.ts"
        , "+++ b/x.ts"
        , "@@ -1,2 +1,2 @@"
        , "-old"
        , "+new"
        , " keep" ]
        `shouldBe` [ DiffMeta "diff --git a/x.ts b/x.ts"
                   , DiffMeta "--- a/x.ts"
                   , DiffMeta "+++ b/x.ts"
                   , DiffHunk "@@ -1,2 +1,2 @@"
                   , DiffDel "-old"
                   , DiffAdd "+new"
                   , DiffPlain " keep" ]

    it "keeps non-diff output as plain lines" $ do
      parseDiffLines ["hello", "world"] `shouldBe` [DiffPlain "hello", DiffPlain "world"]
