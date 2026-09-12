{-# LANGUAGE OverloadedStrings #-}

module UI.Render.Markdown
  ( -- * Data model
    MdBlock(..)
  , MdSpan(..)
    -- * Parsing
  , parseMarkdown
    -- * Plain-text rendering (formatting stripped)
  , renderMarkdownText
  ) where

import Data.Text (Text)
import qualified Data.Text as T

-- | Inline span within a paragraph.
data MdSpan
  = MdPlain Text   -- ^ Plain text
  | MdBold Text    -- ^ @**bold**@
  | MdCode Text    -- ^ @`inline code`@
  deriving (Show, Eq)

-- | Block-level structure.
data MdBlock
  = MdParagraph [MdSpan]
  | MdCodeBlock Text Text -- ^ language, code body
  deriving (Show, Eq)

-- | Parse a subset of Markdown used in assistant replies:
-- paragraphs, @**bold**@, @`code`@ and fenced code blocks (@```lang@).
--
-- * paragraphs are separated by blank lines; line breaks inside a
--   paragraph become single spaces (soft wrap);
-- * an unterminated fence runs to the end of the input.
parseMarkdown :: Text -> [MdBlock]
parseMarkdown doc = go (T.lines doc)
  where
    go :: [Text] -> [MdBlock]
    go [] = []
    go (l : ls)
      | Just lang <- fenceLang l =
          -- body runs until the closing fence; blank lines inside are kept
          let (body, rest) = break isFenceStart ls
          in MdCodeBlock lang (T.intercalate "\n" body) : go (drop 1 rest)
      | T.null (T.strip l) = go ls
      | otherwise =
          let (paraLines, rest) = break isBoundary (l : ls)
              paraText = T.unwords (map T.strip paraLines)
          in MdParagraph (parseParagraph paraText) : go rest

    -- a paragraph ends at a blank line or at a code fence
    isBoundary t = T.null (T.strip t) || isFenceStart t

-- | Does this line open (or close) a code fence?
isFenceStart :: Text -> Bool
isFenceStart = (T.isPrefixOf "```" . T.stripStart)

-- | Extract the language tag when the line opens a fence.
fenceLang :: Text -> Maybe Text
fenceLang l =
  let stripped = T.stripStart l
  in if "```" `T.isPrefixOf` stripped
       then let lang = T.strip (T.drop 3 stripped)
            in if T.null lang then Just "" else Just lang
       else Nothing

-- | Parse inline spans of a paragraph.
parseParagraph :: Text -> [MdSpan]
parseParagraph t = concatMap splitBold (zip [0 :: Int ..] (chop "`" t))
  where
    -- odd segments are inline code; even segments may contain bold
    splitBold (i, seg)
      | odd i = if T.null seg then [] else [MdCode seg]
      | otherwise =
          [ if odd j then MdBold s else MdPlain s
          | (j, s) <- zip [0 :: Int ..] (chop "**" seg)
          , not (T.null s) ]

-- | Split text on a marker, dropping the markers.  Even indexes are text
-- between markers, odd indexes are the segments that were inside markers.
chop :: Text -> Text -> [Text]
chop marker t
  | T.null t = []
  | otherwise =
      case T.breakOn marker t of
        (pre, rest)
          | T.null rest -> [pre]
          | otherwise   -> pre : chop marker (T.drop (T.length marker) rest)

-- | Render a document back to plain text (formatting markers stripped).
renderMarkdownText :: Text -> Text
renderMarkdownText = T.intercalate "\n\n" . map blockText . parseMarkdown

blockText :: MdBlock -> Text
blockText (MdParagraph spans) = T.concat (map spanText spans)
blockText (MdCodeBlock _ code) = code

spanText :: MdSpan -> Text
spanText (MdPlain t) = t
spanText (MdBold t)  = t
spanText (MdCode t)  = t
