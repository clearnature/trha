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
  , classifyPayload
  , isTerminalPayload
  ) where

import Core.Types (ToolEvent)
import Data.Aeson (Value(Object, String), decodeStrict, eitherDecodeStrict')
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
  | SseMessage Text          -- ^ role (user / assistant / ...)
  | SsePlan
  | SseUnknown BS.ByteString
  deriving (Show, Eq)

-- | Classify one payload, keeping the raw bytes for diagnostics.
classifyPayload :: BS.ByteString -> SsePayload
classifyPayload raw
  | Just ev <- parseToolEvent raw = SseTool ev
  | Just (Object o) <- decodeStrict raw
  , Just _ <- KM.lookup "text" o = SseTextDelta raw
  | Just (Object o) <- decodeStrict raw
  , Just (String role) <- KM.lookup "role" o = SseMessage role
  -- plan/approval marker: {status,message} without a tool name — the
  -- approval gate parks the turn; the synchronous reply carries the same
  -- signal, so the stream copy is only silenced here (not re-rendered).
  | Just (Object o) <- decodeStrict raw
  , Just _ <- KM.lookup "status" o
  , Just _ <- KM.lookup "message" o = SsePlan
  | otherwise = SseUnknown raw

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
