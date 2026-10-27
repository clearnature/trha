{-# LANGUAGE OverloadedStrings #-}

-- | Transcript export (MiMo's `dialog-export-options`).
--
-- Pure formatting: the caller reads the transcript (jsonl) and writes the
-- result.  Markdown is for humans; JSON keeps the raw event stream so another
-- tool can re-import it.
module Core.Export
  ( exportMarkdown
  , exportJson
  , defaultExportName
  ) where

import Core.Replay (ReplayBlock(..), renderReplay)
import Data.Aeson (Value, encode, object, (.=))
import qualified Data.ByteString.Lazy as BL
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE

-- | Markdown export: one section per replay block.
exportMarkdown :: Text -> Text -> [Value] -> Text
exportMarkdown sessionId exportedAt events =
  T.unlines $
    [ "# Session " <> sessionId
    , ""
    , "_exported " <> exportedAt <> "_"
    , "_Times are UTC (Z). _"
    , ""
    ] ++ concatMap block (renderReplay events)
  where
    block b = case rbTool b of
      Just (name, args) ->
        [ "## tool · " <> timeOf b
        , ""
        , "```"
        , "[" <> T.pack name <> "] " <> T.unwords args
        , "```"
        , "" ]
      Nothing ->
        [ "## " <> rbRole b <> " · " <> timeOf b
        , ""
        , rbContent b
        , "" ]
    timeOf b = maybe "" id (rbTime b)

-- | JSON export: the raw transcript events plus an envelope.
exportJson :: Text -> Text -> [Value] -> Text
exportJson sessionId exportedAt events =
  TE.decodeUtf8 . BL.toStrict . encode $
    object
      [ "v" .= (1 :: Int)
      , "sessionId" .= sessionId
      , "exportedAt" .= exportedAt
      , "events" .= events
      ]

-- | Default file name: @<sessionId>-<stamp>.md@ / @.json@.
defaultExportName :: Text -> Text -> Text -> FilePath
defaultExportName sessionId exportedAt ext =
  T.unpack (sessionId <> "-" <> T.map safe exportedAt <> "." <> ext)
  where
    safe c | c == ':' || c == ' ' || c == '/' = '-'
           | otherwise = c
