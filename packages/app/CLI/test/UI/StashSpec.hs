{-# LANGUAGE OverloadedStrings #-}

module UI.StashSpec (spec) where

import qualified Data.Text as T
import Test.Hspec
import UI.Stash

spec :: Spec
spec = do
  describe "stashPush / stashPop" $ do
    it "keeps the newest draft first" $ do
      let s = stashPush "second" (stashPush "first" emptyStash)
      stashEntries s `shouldBe` ["second", "first"]

    it "ignores blank input" $
      stashEntries (stashPush "   " emptyStash) `shouldBe` []

    it "moves a duplicate to the front instead of repeating it" $
      stashEntries (stashPush "a" (stashPush "b" (stashPush "a" emptyStash)))
        `shouldBe` ["a", "b"]

    it "caps the stash" $ do
      let s = foldr stashPush emptyStash [T.pack (show n) | n <- [1 .. maxStashEntries + 5 :: Int]]
      length (stashEntries s) `shouldBe` maxStashEntries

    it "pops the newest draft" $ do
      let s = stashPush "new" (stashPush "old" emptyStash)
      stashPop s `shouldBe` Just ("new", Stash ["old"])

    it "has nothing to pop when empty" $
      stashPop emptyStash `shouldBe` Nothing

  describe "line round-trip" $ do
    it "escapes and restores newlines and backslashes" $ do
      let draft = "line1\nline2\\tail"
      entryFromLine (entryToLine draft) `shouldBe` draft

    it "keeps a single-line draft unchanged" $
      entryFromLine (entryToLine "plain draft") `shouldBe` "plain draft"
