{-# LANGUAGE OverloadedStrings #-}

-- | Pure stream-reduction core for the TUI (see "UI.Event").
--
-- M0 (tui-port-plan): the assistant reply accumulates through pure reducers so
-- that streaming deltas from the SSE bridge can be unit-tested without brick.
module UI.EventSpec (spec) where

import Test.Hspec

import Core.Types (StreamChunk(..), Usage(..), mkUsage)
import UI.Event

zeroUsage :: Usage
zeroUsage = mkUsage 0 0 0

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

  describe "runState" $ do
    it "idle when not busy" $ do
      runState False False `shouldBe` RunIdle
      runState False True `shouldBe` RunIdle

    it "awaiting approval wins over running while busy" $ do
      runState True True `shouldBe` RunAwaiting

    it "running while busy without a pending step" $ do
      runState True False `shouldBe` RunRunning

  describe "nextCardFocus" $ do
    it "is Nothing when there are no tool cards" $
      nextCardFocus [] Nothing 1 `shouldBe` Nothing

    it "focuses the newest card when none is focused" $
      nextCardFocus [3, 7, 9] Nothing (-1) `shouldBe` Just 9

    it "moves between cards and clamps at both ends" $ do
      nextCardFocus [3, 7, 9] (Just 7) 1 `shouldBe` Just 9
      nextCardFocus [3, 7, 9] (Just 7) (-1) `shouldBe` Just 3
      nextCardFocus [3, 7, 9] (Just 9) 1 `shouldBe` Just 9
      nextCardFocus [3, 7, 9] (Just 3) (-1) `shouldBe` Just 3

    it "recovers to the newest card when the focus is stale" $
      nextCardFocus [3, 7] (Just 42) 0 `shouldBe` Just 7

  describe "reasoning accumulation" $ do
    it "appends thinking deltas in arrival order" $ do
      let pm = appendReasoning "b" (appendReasoning "a" (newPending "12:00"))
      flushThinking pm `shouldBe` "ab"

    it "keeps reasoning separate from the reply text" $ do
      let pm = reduceChunk (ChunkDelta "answer") (appendReasoning "think" (newPending "12:00"))
      flushThinking pm `shouldBe` "think"
      snd (flushParts pm) `shouldBe` "answer"

    it "is empty when the model sent no reasoning" $
      flushThinking (newPending "12:00") `shouldBe` ""

  describe "shellCommandOf" $ do
    it "recognises the ! prefix" $ do
      shellCommandOf "!ls -la" `shouldBe` Just "ls -la"
      shellCommandOf "  !echo hi  " `shouldBe` Just "echo hi"

    it "ignores a bare ! and ordinary messages" $ do
      shellCommandOf "!" `shouldBe` Nothing
      shellCommandOf "  !   " `shouldBe` Nothing
      shellCommandOf "ls -la" `shouldBe` Nothing
