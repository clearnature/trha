{-# LANGUAGE OverloadedStrings #-}

module UI.CompletionSpec (spec) where

import Test.Hspec
import qualified Data.Text as T
import UI.Completion

opts :: IndexOptions
opts = defaultIndexOptions { ioMaxEntries = 100, ioMaxDepth = 2, ioIgnore = [".git", "node_modules"] }

paths :: [T.Text]
paths =
  [ "src/Main.hs"
  , "src/UI/Brick.hs"
  , "src\\UI\\Layout.hs"        -- normalized to forward slashes
  , "docs/readme.md"
  , ".git/config"
  , "node_modules/react/index.js"
  , "src/node_modules/nested.js"
  , "src/"
  , "src/Main.hs" ]             -- duplicate

spec :: Spec
spec = do
  describe "buildIndex" $ do
    it "normalizes separators and marks directories" $ do
      let ix = buildIndex opts paths
          ps = map compPath ix
      ps `shouldSatisfy` \p -> all (`elem` p)
        ["src/", "src/Main.hs", "src/UI/Brick.hs", "src/UI/Layout.hs"]
      [ compIsDir c | c <- ix, compPath c == "src/" ] `shouldBe` [True]

    it "drops ignored components anywhere in the path" $ do
      let ps = map compPath (buildIndex opts paths)
      ps `shouldNotContain` [".git/config"]
      ps `shouldNotContain` ["node_modules/react/index.js"]
      ps `shouldNotContain` ["src/node_modules/nested.js"]

    it "dedupes" $ do
      let ps = map compPath (buildIndex opts paths)
      length (filter (== "src/Main.hs") ps) `shouldBe` 1

    it "enforces the depth budget" $ do
      let deep = buildIndex opts { ioMaxDepth = 1 } ["a", "a/b", "a/b/c"]
      map compPath deep `shouldBe` ["a", "a/b"]

    it "caps the entry count" $ do
      let many = buildIndex opts { ioMaxEntries = 3 } ["a", "b", "c", "d"]
      length many `shouldBe` 3

  describe "completeIndex" $ do
    it "matches case-insensitively" $ do
      let ix = buildIndex opts ["src/Main.hs", "docs/main.md"]
      map compPath (completeIndex 10 "MAIN" ix)
        `shouldBe` ["src/Main.hs", "docs/main.md"]

    it "ranks path prefixes over basename prefixes over substrings" $ do
      let ix = buildIndex opts ["domain/foo", "src/main.rs", "main/entry", "mains/x"]
      map compPath (completeIndex 10 "main" ix)
        `shouldBe` ["mains/x", "main/entry", "src/main.rs", "domain/foo"]

    it "returns the whole index for an empty query" $ do
      let ix = buildIndex opts ["b", "a"]
      map compPath (completeIndex 10 "" ix) `shouldBe` ["a", "b"]

    it "honours the limit" $ do
      let ix = buildIndex opts ["a", "b", "c"]
      length (completeIndex 2 "" ix) `shouldBe` 2

    it "drops non-matches" $ do
      let ix = buildIndex opts ["src/a"]
      completeIndex 10 "zzz" ix `shouldBe` []

  describe "completionQuery" $ do
    it "finds a token at the end of the text" $ do
      completionQuery "hello @src/ma" 13 `shouldBe` Just (6, "src/ma")

    it "finds a token at the start" $ do
      completionQuery "@a" 2 `shouldBe` Just (0, "a")

    it "stops at the cursor, not the end of the text" $ do
      completionQuery "hi @ab cd" 6 `shouldBe` Just (3, "ab")

    it "returns an empty query for a lone @" $ do
      completionQuery "@" 1 `shouldBe` Just (0, "")

    it "ignores an @ that is not at a token start" $ do
      completionQuery "mail@host" 9 `shouldBe` Nothing

    it "returns Nothing when the cursor is not in a token" $ do
      completionQuery "no token" 8 `shouldBe` Nothing
      completionQuery "" 0 `shouldBe` Nothing

  describe "applyCompletion" $ do
    it "replaces the token with the path" $ do
      applyCompletion "hello @sr world" 6 9 (Completion "src/" True)
        `shouldBe` "hello src/ world"

    it "inserts a file path" $ do
      applyCompletion "see @ma" 4 7 (Completion "src/Main.hs" False)
        `shouldBe` "see src/Main.hs"

  describe "completion popup" $ do
    let ix = buildIndex opts ["src/Main.hs", "src/UI/Brick.hs", "docs/readme.md"]

    it "opens with the matches and the token span" $ do
      let Just cs = completionPopup 8 ix "open @src" 9
      csStart cs `shouldBe` 5
      csEnd cs `shouldBe` 9
      csSel cs `shouldBe` 0
      map compPath (csItems cs) `shouldBe` ["src/Main.hs", "src/UI/Brick.hs"]

    it "stays closed when nothing matches or there is no token" $ do
      completionPopup 8 ix "open @zzz" 9 `shouldBe` Nothing
      completionPopup 8 ix "no token" 8 `shouldBe` Nothing

    it "moves and clamps the selection" $ do
      let Just cs = completionPopup 8 ix "@src" 4
      csSel (moveCompletion 1 cs) `shouldBe` 1
      csSel (moveCompletion 9 cs) `shouldBe` 1
      csSel (moveCompletion (-9) cs) `shouldBe` 0

    it "applies the highlighted candidate" $ do
      let Just cs = completionPopup 8 ix "see @src" 8
      applySelected "see @src" cs `shouldBe` Just "see src/Main.hs"
      applySelected "see @src" (cs { csSel = 1 }) `shouldBe` Just "see src/UI/Brick.hs"
