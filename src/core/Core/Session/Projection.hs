{-# LANGUAGE OverloadedStrings #-}

-- | Session truth projection: rebuild the model-visible message sequence from
-- the kernel's event log.
--
-- This is the Haskell half of the contract in
-- @docs/contracts/session-truth.md@: the kernel event log is the authority for
-- model-visible history, and a scheduler-restored session must be derivable
-- from it.  The rules here are mirrored by
-- @packages/scheduler/src/Core/SessionTruth.ts@ (same fixture, same output).
module Core.Session.Projection
  ( SessionMessage(..)
  , eventsToMessages
  ) where

import Data.Aeson (Value, encode, object, (.=))
import qualified Data.ByteString.Lazy as BL
import qualified Data.Text.Encoding as TE
import Data.Text (Text)
import qualified Data.Text as T

import Core.Session.Types

-- | A normalized, provider-independent message.  Tool calls use a stable
-- @{name, arguments}@ shape (the kernel event log has no provider call id).
data SessionMessage = SessionMessage
  { smRole      :: Text
  , smContent   :: Text
  , smToolCalls :: Maybe [Value]
  , smName      :: Maybe Text
  } deriving (Show, Eq)

-- | Pure projection.  State/plan/approval events are not messages and are
-- skipped; the FSM state is a fold over the same log
-- ('SessionSnapshot.snapshotEventCount' tells recovery where to resume).
eventsToMessages :: [SessionEvent] -> [SessionMessage]
eventsToMessages = foldr step []
  where
    step (UserMessage t)      acc = SessionMessage "user" t Nothing Nothing : acc
    step (AssistantMessage t) acc = SessionMessage "assistant" t Nothing Nothing : acc
    step (SystemEvent s)      acc = SessionMessage "system" (T.pack s) Nothing Nothing : acc
    step (ToolCall n p)       acc =
      SessionMessage "assistant" ""
        (Just [object ["name" .= n, "arguments" .= p]])
        Nothing : acc
    step (ToolResult n p)     acc =
      SessionMessage "tool" (jsonText p) Nothing (Just (T.pack n)) : acc
    step _                    acc = acc

jsonText :: Value -> Text
jsonText = TE.decodeUtf8 . BL.toStrict . encode
