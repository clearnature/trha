{-# LANGUAGE OverloadedStrings #-}

-- | Pure replay projection: transcript events -> display blocks
-- (Phase 2 S3 resume).  Follows haskell-agent's idea that replay renders
-- with the same rules as the live view; the brick layer turns blocks into
-- widgets.
module Core.Replay
  ( ReplayBlock(..)
  , renderReplay
  , renderReplayText
  ) where

import Core.Types (ToolName)
import Data.Aeson (Value(..))
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.Foldable (toList)
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T

-- | One display block reconstructed from a transcript event.
data ReplayBlock = ReplayBlock
  { rbRole    :: Text            -- ^ user / assistant / tool / system / error
  , rbContent :: Text
  , rbTime    :: Maybe Text
  , rbTool    :: Maybe (ToolName, [Text])
  } deriving (Show, Eq)

-- | Project transcript event lines (Core.Transcript jsonl schema) into
-- replay blocks.  Session-created events are skipped; unknown or
-- malformed events are skipped (loadTranscript already filters unparseable
-- JSON; this filters semantically unrecognised lines).
renderReplay :: [Value] -> [ReplayBlock]
renderReplay = mapMaybe toBlock
  where
    toBlock :: Value -> Maybe ReplayBlock
    toBlock v = case eventOf v of
      Just "user"      -> plain "user" v
      Just "assistant" -> plain "assistant" v
      Just "error"     -> plain "error" v
      Just "tool"      -> toolBlock v
      Just "done"      -> doneBlock v
      _                -> Nothing -- incl. "session" and unknown kinds

    plain :: Text -> Value -> Maybe ReplayBlock
    plain role v = do
      content <- fieldOf v "content"
      return ReplayBlock
        { rbRole = role, rbContent = content
        , rbTime = fieldOf v "ts", rbTool = Nothing }

    toolBlock :: Value -> Maybe ReplayBlock
    toolBlock v = do
      name <- fieldOf v "tool"
      args <- fieldOfList v "args"
      return ReplayBlock
        { rbRole = "tool", rbContent = ""
        , rbTime = fieldOf v "ts", rbTool = Just (T.unpack name, args) }

    doneBlock :: Value -> Maybe ReplayBlock
    doneBlock v = do
      tokens <- usageTokens v
      return ReplayBlock
        { rbRole = "system"
        , rbContent = "✓ " <> T.pack (show tokens) <> " tokens"
        , rbTime = fieldOf v "ts", rbTool = Nothing }

    -- {"usage":{"usageTotalTokens":N}}
    usageTokens :: Value -> Maybe Int
    usageTokens v = case v of
      Object o -> case KM.lookup (K.fromText "usage") o of
        Just (Object uo) -> case KM.lookup (K.fromText "usageTotalTokens") uo of
          Just (Number n) -> Just (truncate n)
          _               -> Nothing
        _ -> Nothing
      _ -> Nothing

--------------------------------------------------------------------------------
-- Plain-text rendering (REPL replay display)
--------------------------------------------------------------------------------

-- | Render replay blocks as plain text lines with role labels
-- (plain-text mirror of the TUI rules).
renderReplayText :: [ReplayBlock] -> Text
renderReplayText = T.intercalate "\n\n" . map blockText

blockText :: ReplayBlock -> Text
blockText b =
  T.intercalate "\n" $
    [ "[" <> rbRole b <> "] " <> maybe "" id (rbTime b) ]
      ++ bodyLines (rbTool b) (rbContent b)
  where
    bodyLines (Just (name, args)) _ =
      ["  [tool] " <> T.pack name
        <> if null args then "" else " " <> T.unwords args]
    bodyLines Nothing content = ["  " <> line | line <- T.lines content]

--------------------------------------------------------------------------------
-- Field lookup helpers
--------------------------------------------------------------------------------

eventOf :: Value -> Maybe Text
eventOf v = fieldOf v "event"

fieldOf :: Value -> Text -> Maybe Text
fieldOf v key = case v of
  Object o -> case KM.lookup (K.fromText key) o of
    Just (String t) -> Just t
    _               -> Nothing
  _ -> Nothing

-- | Extract a list-of-text field (tool args); a missing key defaults to
-- an empty list, a present-but-wrong-typed value is treated as absent.
fieldOfList :: Value -> Text -> Maybe [Text]
fieldOfList v key = case v of
  Object o -> case KM.lookup (K.fromText key) o of
    Just (Array arr) -> Just [ t | String t <- toList arr ]
    _                -> Just []
  _ -> Nothing
