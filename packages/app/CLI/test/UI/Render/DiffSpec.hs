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

  describe "hunkStart" $ do
    it "parses start lines with counts" $ do
      hunkStart "@@ -10,2 +20,3 @@ fn main" `shouldBe` Just (10, 20)

    it "parses start lines without counts" $ do
      hunkStart "@@ -1 +1 @@" `shouldBe` Just (1, 1)

    it "rejects non-hunk lines" $ do
      hunkStart "--- a/x.ts" `shouldBe` Nothing
      hunkStart "@@not a hunk" `shouldBe` Nothing

  describe "numberDiff" $ do
    it "numbers context, removed and added lines from the hunk header" $ do
      let rows = numberDiff ["@@ -10,2 +20,2 @@", " keep", "-old", "+new"]
      map (\r -> (drClass r, drOld r, drNew r)) rows
        `shouldBe` [ (CHunk, Nothing, Nothing)
                   , (CPlain, Just 10, Just 20)
                   , (CDel, Just 11, Nothing)
                   , (CAdd, Nothing, Just 21) ]

    it "leaves lines outside a hunk unnumbered" $ do
      let rows = numberDiff ["diff --git a/x b/x", "hello", "@@ -1 +1 @@", "+new"]
      map drOld (take 2 rows) `shouldBe` [Nothing, Nothing]
      map drNew (take 2 rows) `shouldBe` [Nothing, Nothing]

    it "does not treat file headers as hunk starts" $ do
      let rows = numberDiff ["--- a/x", "+++ b/x"]
      map drClass rows `shouldBe` [CMeta, CMeta]
      map drOld rows `shouldBe` [Nothing, Nothing]

  describe "diff layout" $ do
    it "inlines below 120 columns and numbers from 120 up" $ do
      diffLayout 119 `shouldBe` DiffInline
      diffLayout 120 `shouldBe` DiffNumbered

    it "renders the inline form as the raw line" $ do
      renderDiffRow DiffInline (DiffRow CAdd Nothing (Just 7) "+new")
        `shouldBe` "+new"

    it "renders a 4+4 gutter in the numbered form" $ do
      renderDiffRow DiffNumbered (DiffRow CDel (Just 12) Nothing "-old")
        `shouldBe` "  12      │ -old"
      renderDiffRow DiffNumbered (DiffRow CAdd Nothing (Just 7) "+new")
        `shouldBe` "        7 │ +new"

  describe "looksLikeDiff" $ do
    it "requires a hunk header" $ do
      looksLikeDiff ["@@ -1 +1 @@", "+x"] `shouldBe` True
      looksLikeDiff ["- not a diff", "+ not a diff"] `shouldBe` False
      looksLikeDiff [] `shouldBe` False
