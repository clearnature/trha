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
  ) where

import Core.Types (ToolEvent)
import Data.Aeson (eitherDecodeStrict')
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC

-- | Decoder state: bytes not yet forming a complete line.
data SseDecoder = SseDecoder
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
