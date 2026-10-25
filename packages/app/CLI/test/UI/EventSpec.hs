{-# LANGUAGE OverloadedStrings #-}

-- | Pure stream-reduction core for the TUI (see "UI.Event").
--
-- M0 (tui-port-plan): the assistant reply accumulates through pure reducers so
-- that streaming deltas from the SSE bridge can be unit-tested without brick.
module UI.EventSpec (spec) where

import Test.Hspec

import Core.Types (StreamChunk(..), Usage(..))
import UI.Event

zeroUsage :: Usage
zeroUsage = Usage 0 0 0

spec :: Spec
spec = describe "UI.Event" $ do
  describe "reduceChunk" $ do
    it "appends text deltas in arrival order" $ do
      let pm0 = newPending "12:00"
          pm1 = reduceChunk (ChunkDelta "Hel") pm0
          pm2 = reduceChunk (ChunkDelta "lo") pm1
      pmContent pm2 `shouldBe` "Hello"
      pmStart pm2 `shouldBe` "12:00"

    it "records tool invocations newest-first" $ do
      let pm = reduceChunk (ChunkToolCall "bash" ["ls"]) $
               reduceChunk (ChunkToolCall "read" ["a.txt"]) (newPending "t")
      map tiName (pmTools pm) `shouldBe` ["bash", "read"] -- newest first

    it "interleaves deltas and tool calls without losing either" $ do
      let pm = foldl (flip reduceChunk) (newPending "t")
                 [ChunkDelta "a", ChunkToolCall "bash" [], ChunkDelta "b"]
      pmContent pm `shouldBe` "ab"
      length (pmTools pm) `shouldBe` 1

  describe "newPending" $ do
    it "starts empty with the given timestamp" $ do
      let pm = newPending "start"
      pmContent pm `shouldBe` ""
      pmTools pm `shouldBe` []
      pmStart pm `shouldBe` "start"

  describe "flushParts" $ do
    it "splits into tool cards then assistant text, in chronological order" $ do
      let pm = foldl (flip reduceChunk) (newPending "t")
                 [ChunkDelta "  ", ChunkToolCall "bash" ["ls"], ChunkDelta "hello"]
          (tools, content) = flushParts pm
      map tiName tools `shouldBe` ["bash"]
      map tiArgs tools `shouldBe` [["ls"]]
      content `shouldBe` "hello"

    it "yields no assistant message for whitespace-only content" $ do
      let pm = reduceChunk (ChunkDelta "   ") (newPending "t")
      flushParts pm `shouldBe` ([], "")
