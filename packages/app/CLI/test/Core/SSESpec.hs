{-# LANGUAGE OverloadedStrings #-}

module Core.SSESpec (spec) where

import Test.Hspec
import Core.SSE
import Core.Types (ToolEvent(..), ToolRunStatus(..))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import Data.Text (Text)

spec :: Spec
spec = do
  describe "feed" $ do
    it "extracts data payloads from a full frame" $ do
      let chunk = BC.pack "data: {\"a\":1}\n\ndata: {\"b\":2}\n\n"
      fst (feed newDecoder chunk) `shouldBe` [ "{\"a\":1}", "{\"b\":2}" ]

    it "ignores event names, comments and empty lines" $ do
      let chunk = BC.pack "event: tool:update\ndata: {\"a\":1}\n\n: heartbeat\n\n"
      fst (feed newDecoder chunk) `shouldBe` ["{\"a\":1}"]

    it "keeps an incomplete trailing line for the next chunk" $ do
      let (p1, d1) = feed newDecoder (BC.pack "data: {\"a\"")
          (p2, d2) = feed d1 (BC.pack ":1}\n\n")
      p1 `shouldBe` []
      p2 `shouldBe` ["{\"a\":1}"]
      pendingBytes d2 `shouldBe` BC.pack ""

    it "handles CRLF line endings" $ do
      let chunk = BC.pack "data: {\"a\":1}\r\n\r\n"
      fst (feed newDecoder chunk) `shouldBe` ["{\"a\":1}"]

    it "treats an empty data line as an empty payload" $ do
      fst (feed newDecoder (BC.pack "data:\n\n")) `shouldBe` [""]

  describe "parseToolEvent" $ do
    it "decodes a running tool event payload" $ do
      let payload = BC.pack "{\"name\":\"bash\",\"args\":[\"ls\"],\"status\":\"running\"}"
      fmap teName (parseToolEvent payload) `shouldBe` Just "bash"

    it "rejects non-JSON payloads" $ do
      parseToolEvent (BC.pack "not json") `shouldBe` Nothing

    it "rejects unknown statuses" $ do
      parseToolEvent (BC.pack "{\"name\":\"x\",\"status\":\"??\"}") `shouldBe` Nothing

  -- Shapes taken from a live /api/events/:id stream: the scheduler puts tool
  -- progress, text deltas and message echoes on the same connection.
  describe "classifyPayload" $ do
    it "calls the tool payload a tool event" $ do
      let raw = BC.pack "{\"sessionId\":\"s1\",\"name\":\"read_file\",\"args\":[\"path=/etc/hostname\"],\"status\":\"succeeded\",\"durationMs\":1}"
      case classifyPayload raw of
        SseTool ev -> do
          teName ev `shouldBe` "read_file"
          teStatus ev `shouldBe` ToolRunSucceeded
        other -> expectationFailure ("expected a tool event, got " <> show other)

    it "does not mistake a text delta for a tool event" $ do
      classifyPayload (BC.pack "{\"sessionId\":\"s1\",\"text\":\"[\"}")
        `shouldSatisfy` isDelta

    it "recognises a message echo and keeps its role" $ do
      classifyPayload (BC.pack "{\"sessionId\":\"s1\",\"role\":\"assistant\",\"content\":\"hi\"}")
        `shouldBe` SseMessage "assistant"

    it "marks assistant echoes and the plan gate as terminal" $ do
      isTerminalPayload (SseMessage "assistant") `shouldBe` True
      isTerminalPayload (SseMessage "user")      `shouldBe` False
      isTerminalPayload SsePlan                  `shouldBe` True
      isTerminalPayload (SseTextDelta "{}")      `shouldBe` False

    it "keeps unrecognised payloads for diagnostics" $ do
      case classifyPayload (BC.pack "{\"weird\":true}") of
        SseUnknown raw -> raw `shouldBe` "{\"weird\":true}"
        other -> expectationFailure ("expected unknown, got " <> show other)

    it "recognises reasoning deltas by their key" $ do
      classifyPayload (BC.pack "{\"sessionId\":\"s1\",\"reasoning\":\"think\"}")
        `shouldBe` SseReasoning "think"

    it "recognises a step boundary (agent:model-request)" $ do
      classifyPayload (BC.pack "{\"sessionId\":\"s1\",\"round\":2,\"messageCount\":7,\"toolCount\":3}")
        `shouldBe` SseStep 2 7 3

    it "recognises a context compaction (agent:context)" $ do
      classifyPayload (BC.pack "{\"sessionId\":\"s1\",\"trigger\":\"fold\",\"savedTokens\":420,\"prefixChanged\":true}")
        `shouldBe` SseCompaction "fold" 420

    it "maps only the side-channel shapes to notices" $ do
      toNotice (SseReasoning "t") `shouldBe` Just (ReasoningDelta "t")
      toNotice (SseStep 1 2 3)    `shouldBe` Just (StepStarted 1 2 3)
      toNotice (SseCompaction "fold" 9) `shouldBe` Just (ContextCompacted "fold" 9)
      toNotice (SseMessage "assistant") `shouldBe` Nothing
      toNotice SsePlan `shouldBe` Nothing

    it "recognises a retry notice (agent:retry)" $ do
      classifyPayload (BC.pack "{\"sessionId\":\"s1\",\"attempt\":1,\"delayMs\":500,\"reason\":\"429\"}")
        `shouldBe` SseRetry 1 500 "429"

    it "maps the retry shape to a notice" $
      toNotice (SseRetry 2 1000 "503") `shouldBe` Just (RetryScheduled 2 1000 "503")
  where
    isDelta (SseTextDelta _) = True
    isDelta _                = False
