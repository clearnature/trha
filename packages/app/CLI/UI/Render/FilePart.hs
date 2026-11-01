{-# LANGUAGE OverloadedStrings #-}

-- | File references carried inside a message (MiMo's @FilePart@).
--
-- The composer inserts @[image: …]@ / @[voice: …]@ tokens when a clipboard
-- image or a recording is attached (M9-8 / M9-9).  Rendering them as plain
-- prose would show the path twice (once as text, once when the user reads
-- the message), so this module splits the tokens off: the remaining prose is
-- wrapped normally and each reference gets one attachment row.
module UI.Render.FilePart
  ( FileKind(..)
  , FileRef(..)
  , filePartsOf
  , stripFileTokens
  , filePartLine
  , filePartLines
  ) where

import Data.Text (Text)
import qualified Data.Text as T

-- | What the reference points at.  The UI only needs the label.
data FileKind = FkImage | FkVoice | FkFile
  deriving (Show, Eq)

-- | One @[kind: path]@ token.
data FileRef = FileRef
  { frKind :: FileKind
  , frPath :: Text
  } deriving (Show, Eq)

-- | Attachments mentioned in a message, in order and de-duplicated.
filePartsOf :: Text -> [FileRef]
filePartsOf = dedupe . scan . T.unpack
  where
    scan [] = []
    scan ('[' : cs) = case tokenAt cs of
      Just (kind, path, after) -> FileRef kind (T.strip (T.pack path)) : scan after
      Nothing                  -> scan cs
    scan (_ : cs) = scan cs

-- | Message text with the attachment tokens removed.  Surrounding spaces are
-- collapsed so "look [image: a.png] here" reads "look here".  Text without
-- tokens is returned untouched (wrapping and newlines preserved).
stripFileTokens :: Text -> Text
stripFileTokens t
  | null (filePartsOf t) = t
  | otherwise = T.unwords . T.words . T.pack . go . T.unpack $ t
  where
    go [] = []
    go ('[' : cs) = case tokenAt cs of
      Just (_, _, after) -> ' ' : go after
      Nothing            -> '[' : go cs
    go (c : cs) = c : go cs

-- | One attachment row, e.g. @▣ image  ~/.trha/paste/1700000000.png@.
filePartLine :: FileRef -> Text
filePartLine r = "▣ " <> kindLabel (frKind r) <> "  " <> frPath r

filePartLines :: [FileRef] -> [Text]
filePartLines = map filePartLine

kindLabel :: FileKind -> Text
kindLabel FkImage = "image"
kindLabel FkVoice = "voice"
kindLabel FkFile  = "file"

-- | Consume @kind: path]@ (the @[@ is already eaten).  The path may contain
-- colons (Windows drive letters), so only the first @:@ separates.
tokenAt :: String -> Maybe (FileKind, String, String)
tokenAt cs =
  case lookupKind (T.toLower (T.strip (T.pack tag))) of
    Just kind
      | not (null rest) ->
          let (body, after) = break (== ']') (drop 1 rest)
          in case after of
               []          -> Nothing
               (_ : more)  -> Just (kind, body, more)
    _ -> Nothing
  where
    (tag, rest) = break (== ':') cs

lookupKind :: Text -> Maybe FileKind
lookupKind "image" = Just FkImage
lookupKind "voice" = Just FkVoice
lookupKind "file"  = Just FkFile
lookupKind _       = Nothing

dedupe :: [FileRef] -> [FileRef]
dedupe = go []
  where
    go _ [] = []
    go seen (r : rs)
      | r `elem` seen = go seen rs
      | otherwise     = r : go (r : seen) rs
