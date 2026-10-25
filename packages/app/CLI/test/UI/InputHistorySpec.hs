{-# LANGUAGE OverloadedStrings #-}

module UI.InputHistorySpec (spec) where

import Test.Hspec
import qualified Data.Text as T

import UI.InputHistory

spec :: Spec
spec = do
  describe "histUp" $ do
    it "shows the newest entry and stashes the draft" $ do
      histUp "draft" (HistState ["e2", "e1"] Nothing Nothing)
        `shouldBe` Just (HistState ["e2", "e1"] (Just 0) (Just "draft"), "e2")

    it "moves to older entries while navigating" $ do
      histUp "x" (HistState ["e2", "e1"] (Just 0) (Just "draft"))
        `shouldBe` Just (HistState ["e2", "e1"] (Just 1) (Just "draft"), "e1")

    it "stays put at the oldest entry" $ do
      histUp "x" (HistState ["only"] (Just 0) (Just "draft")) `shouldBe` Nothing

    it "does nothing with empty history" $ do
      histUp "x" emptyHistState `shouldBe` Nothing

  describe "histDown" $ do
    it "restores the draft past the newest entry" $ do
      histDown (HistState ["e2", "e1"] (Just 0) (Just "draft"))
        `shouldBe` Just (HistState ["e2", "e1"] Nothing Nothing, "draft")

    it "restores an empty draft as empty input" $ do
      histDown (HistState ["only"] (Just 0) (Just ""))
        `shouldBe` Just (HistState ["only"] Nothing Nothing, "")

    it "moves to the next newer entry" $ do
      histDown (HistState ["e2", "e1"] (Just 1) (Just "draft"))
        `shouldBe` Just (HistState ["e2", "e1"] (Just 0) (Just "draft"), "e2")

    it "does nothing when not navigating" $ do
      histDown emptyHistState `shouldBe` Nothing

  describe "histCommit" $ do
    it "pushes the entry to the front and clears navigation" $ do
      histCommit "hello" (HistState ["old"] (Just 0) (Just "d"))
        `shouldBe` HistState ["hello", "old"] Nothing Nothing

    it "does not duplicate the newest entry" $ do
      histCommit "new" (HistState ["new", "old"] Nothing Nothing)
        `shouldBe` HistState ["new", "old"] Nothing Nothing

    it "ignores empty entries" $ do
      histCommit "" emptyHistState `shouldBe` emptyHistState

    it "caps the history length" $ do
      let many = map (T.pack . show) [1 .. maxHistEntries :: Int]
          hs = HistState many Nothing Nothing
          expected = T.pack (show (maxHistEntries + 1)) : many
      histCommit "101" hs `shouldBe` HistState (take maxHistEntries expected) Nothing Nothing

  describe "file format" $ do
    it "escapes newlines in stored entries" $ do
      entryToLine "a\nb" `shouldBe` "a\\nb"

    it "restores escaped newlines on load" $ do
      entryFromLine "a\\nb" `shouldBe` "a\nb"

    it "round-trips multi-line entries" $ do
      entryFromLine (entryToLine "line1\nline2") `shouldBe` "line1\nline2"

    it "parses a history file newest-first, dropping empties" $ do
      historyEntriesFromLines ["old", "", "new"] `shouldBe` ["new", "old"]

    it "caps loaded entries at the newest end" $ do
      let many = map (T.pack . show) [1 .. (maxHistEntries + 5) :: Int]
          loaded = historyEntriesFromLines many
      length loaded `shouldBe` maxHistEntries
      head loaded `shouldBe` T.pack (show (maxHistEntries + 5))
