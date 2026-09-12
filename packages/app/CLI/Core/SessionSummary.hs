{-# LANGUAGE OverloadedStrings #-}

-- | Pure session-summary projection over local transcript events
-- (Phase 2 S3 resume).  Kept dependency-light (aeson + text only) so the
-- index logic is unit-testable without pulling in the whole transcript
-- I/O chain.
module Core.SessionSummary
  ( -- * Summary
    SessionSummary(..)
    -- * Projection
  , sessionSummaryOf
    -- * Selection
  , pickLocalSession
    -- * Titles
  , summaryTitle
  , defaultTitle
  ) where

import Core.Types (SessionId)
import Data.Aeson (Value(..))
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.Char (isDigit)
import Data.List (find)
import Data.Text (Text)
import qualified Data.Text as T

-- | Index entry for one local session, derived from its transcript.
data SessionSummary = SessionSummary
  { ssId      :: SessionId
  , ssTitle   :: Text
  , ssTurns   :: Int        -- ^ number of user turns
  , ssModel   :: Maybe Text
  , ssLastTs  :: Maybe Text -- ^ timestamp of the last recorded event
  } deriving (Show, Eq)

-- | Fallback title when a session has no user message yet.
defaultTitle :: SessionId -> Text
defaultTitle sid = "Untitled " <> T.pack sid

-- | Title text for a user message (truncated for list display).
summaryTitle :: Text -> Text
summaryTitle = truncateTo 48

-- | Project a summary from the transcript event values of one session.
--
-- Event lines follow Core.Transcript's jsonl schema:
-- @{"ts","event","session",…}@ with @event@ in
-- session/user/assistant/tool/done/error.
sessionSummaryOf :: SessionId -> [Value] -> SessionSummary
sessionSummaryOf sid events =
  SessionSummary
    { ssId = sid
    , ssTitle = maybe (defaultTitle sid) summaryTitle firstUser
    , ssTurns = length userEvents
    , ssModel = modelOf
    , ssLastTs = lastTsOf
    }
  where
    userEvents = [ v | v <- events, eventOf v == Just "user" ]
    firstUser = case userEvents of
      (v : _) -> fieldOf v "content"
      []      -> Nothing
    modelOf = case [ v | v <- events, eventOf v == Just "session" ] of
      (v : _) -> fieldOf v "model"
      []      -> Nothing
    lastTsOf = case reverse events of
      (v : _) -> fieldOf v "ts"
      []      -> Nothing

    eventOf :: Value -> Maybe Text
    eventOf v = fieldOf v "event"

    fieldOf :: Value -> Text -> Maybe Text
    fieldOf (Object o) key = case KM.lookup (K.fromText key) o of
      Just (String t) -> Just t
      _               -> Nothing
    fieldOf _ _ = Nothing

-- | Select a session summary by 1-based list number or by session id.
pickLocalSession :: String -> [SessionSummary] -> Maybe SessionSummary
pickLocalSession sel sessions
  | not (null sel) && all isDigit sel =
      case reads sel of
        ((n, _) : _) | n >= 1 -> case drop (n - 1) sessions of
          (s : _) -> Just s
          []      -> Nothing
        _ -> Nothing
  | otherwise = find ((== sel) . ssId) sessions

-- | Truncate text to n characters, appending an ellipsis when cut.
truncateTo :: Int -> Text -> Text
truncateTo n t
  | T.length t <= n = t
  | otherwise = T.take (n - 1) t <> "…"
