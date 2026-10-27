{-# LANGUAGE OverloadedStrings #-}

-- | Minimal incremental SSE decoder (pure, unit-testable).  The CLI Bridge
-- feeds raw body chunks in; completed @data:@ payloads come out.  Event
-- names, comments and heartbeat lines are ignored -- only @data:@ lines
-- matter for the tool-event stream.
module Core.SSE
  ( SseDecoder(..)
  , newDecoder
  , feed
  , parseToolEvent
  , SsePayload(..)
  , SseNotice(..)
  , classifyPayload
  , toNotice
  , isTerminalPayload
  ) where

import Core.Types (ToolEvent)
import Data.Aeson (Value(Object, String), decodeStrict, eitherDecodeStrict')
import Data.Aeson.Types (parseMaybe, (.:))
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import Data.Text (Text)

-- | Decoder state: bytes not yet forming a complete line.
newtype SseDecoder = SseDecoder
  { pendingBytes :: BS.ByteString
  } deriving (Show, Eq)

-- | A fresh decoder.
newDecoder :: SseDecoder
newDecoder = SseDecoder BS.empty

-- | Feed a chunk of body bytes; return the completed data payloads.
-- An incomplete trailing line is kept in the decoder for the next chunk.
feed :: SseDecoder -> BS.ByteString -> ([BS.ByteString], SseDecoder)
feed (SseDecoder pend) chunk =
  let joined = pend <> chunk
      (completeLines, rest) = splitLines joined
  in (mapMaybeData completeLines, SseDecoder rest)

-- | Split at newlines; the trailing partial line (no newline yet) is
-- returned as the remainder.
splitLines :: BS.ByteString -> ([BS.ByteString], BS.ByteString)
splitLines bs = go [] bs
  where
    go acc b = case BC.elemIndex '\n' b of
      Nothing -> (reverse acc, b)
      Just i  ->
        let (l, rest) = BS.splitAt i b
            l' = stripCR l
        in go (l' : acc) (BS.drop 1 rest)
    stripCR = BC.dropWhileEnd (== '\r')

-- | Keep only @data:@ payloads (data: with no space also accepted).
mapMaybeData :: [BS.ByteString] -> [BS.ByteString]
mapMaybeData = foldr step []
  where
    step line acc
      | "data:" `BC.isPrefixOf` line =
          BC.dropWhile (== ' ') (BC.drop 5 line) : acc
      | otherwise = acc

-- | Decode one payload line into a 'ToolEvent'.
parseToolEvent :: BS.ByteString -> Maybe ToolEvent
parseToolEvent = either (const Nothing) Just . eitherDecodeStrict'

-- | What one @data:@ payload on @/api/events/:id@ actually is.
--
-- The scheduler interleaves three shapes on one stream: tool progress
-- (@name@ + @status@), assistant text deltas (@text@), and message echoes
-- (@role@ + @content@). Treating every payload as a tool event turned each
-- text delta into @ValidationError \"Invalid tool event payload\"@, which the
-- TUI painted as a red error row on every answer.
data SsePayload
  = SseTool ToolEvent
  | SseTextDelta BS.ByteString
  | SseReasoning Text        -- ^ thinking delta (agent:reasoning)
  | SseStep Int Int Int      -- ^ round, message count, tool count (agent:model-request)
  | SseCompaction Text Int   -- ^ trigger, tokens saved (agent:context)
  | SseRetry Int Int Text    -- ^ attempt, delay ms, reason (agent:retry)
  | SseMessage Text          -- ^ role (user / assistant / ...)
  | SsePlan
  | SseUnknown BS.ByteString
  deriving (Show, Eq)

-- | Structured side-channel events the TUI renders as cards/rows.  Kept
-- separate from 'SsePayload' so the bridge can hand them to one sink.
data SseNotice
  = ReasoningDelta Text
  | StepStarted Int Int Int
  | ContextCompacted Text Int
  | RetryScheduled Int Int Text
  deriving (Show, Eq)

-- | Classify one payload, keeping the raw bytes for diagnostics.
classifyPayload :: BS.ByteString -> SsePayload
classifyPayload raw =
  case parseToolEvent raw of
    Just ev -> SseTool ev
    Nothing -> case decodeStrict raw of
      Just (Object o) -> fromObject o
      _ -> SseUnknown raw
  where
    fromObject o
      | Just (String r) <- KM.lookup "reasoning" o = SseReasoning r
      | Just _ <- KM.lookup "text" o = SseTextDelta raw
      | Just n <- asCompaction o = n
      | Just n <- asRetry o = n
      | Just n <- asStep o = n
      | Just (String role) <- KM.lookup "role" o = SseMessage role
      -- plan/approval marker: {status,message} without a tool name — the
      -- approval gate parks the turn; the synchronous reply carries the same
      -- signal, so the stream copy is only silenced here (not re-rendered).
      | Just _ <- KM.lookup "status" o
      , Just _ <- KM.lookup "message" o = SsePlan
      | otherwise = SseUnknown raw
    asStep o =
      SseStep
        <$> parseMaybe (.: "round") o
        <*> parseMaybe (.: "messageCount") o
        <*> parseMaybe (.: "toolCount") o
    asCompaction o =
      SseCompaction
        <$> parseMaybe (.: "trigger") o
        <*> parseMaybe (.: "savedTokens") o
    asRetry o =
      SseRetry
        <$> parseMaybe (.: "attempt") o
        <*> parseMaybe (.: "delayMs") o
        <*> parseMaybe (.: "reason") o

-- | The structured event behind a payload, when there is one.
toNotice :: SsePayload -> Maybe SseNotice
toNotice (SseReasoning t)   = Just (ReasoningDelta t)
toNotice (SseStep r m t)    = Just (StepStarted r m t)
toNotice (SseCompaction tr n) = Just (ContextCompacted tr n)
toNotice (SseRetry a d r)     = Just (RetryScheduled a d r)
toNotice _ = Nothing

-- | Whether a payload marks the end of a turn on the session stream.
--
-- The scheduler emits the assistant's message echo (or the plan gate) after
-- every tool event of that turn, and one SSE connection preserves order, so
-- receiving a terminal payload guarantees that all preceding tool updates
-- were already delivered.  The TUI uses this instead of sleeping before it
-- tears the subscription down.
isTerminalPayload :: SsePayload -> Bool
isTerminalPayload (SseMessage "assistant") = True
isTerminalPayload SsePlan                  = True
isTerminalPayload _                        = False
