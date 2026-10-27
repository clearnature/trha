{-# LANGUAGE OverloadedStrings #-}

-- | Draft stash (MiMo's `dialog-stash`): park the composer text and get it
-- back later.  Newest first, de-duplicated, capped; persisted to
-- @~/.trha/stash.jsonl@ one entry per line (newlines escaped like the input
-- history file).
module UI.Stash
  ( Stash(..)
  , emptyStash
  , maxStashEntries
  , stashPush
  , stashPop
  , stashEntries
  , entryToLine
  , entryFromLine
  , defaultStashPath
  , loadStash
  , saveStash
  ) where

import Control.Exception (IOException, try)
import Control.Monad (when)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Directory (doesFileExist, renameFile)
import System.FilePath ((</>))
import Core.StatePaths (stateReadPath, stateWritePath)

-- | Draft stash, newest first.
newtype Stash = Stash { stashEntries :: [Text] }
  deriving (Show, Eq)

emptyStash :: Stash
emptyStash = Stash []

-- | Cap so the file and the picker stay small.
maxStashEntries :: Int
maxStashEntries = 50

-- | Push a draft (ignoring blank input and moving a duplicate to the front).
stashPush :: Text -> Stash -> Stash
stashPush entry (Stash xs)
  | T.null (T.strip entry) = Stash xs
  | otherwise = Stash (take maxStashEntries (entry : filter (/= entry) xs))

-- | Pop the newest draft.
stashPop :: Stash -> Maybe (Text, Stash)
stashPop (Stash []) = Nothing
stashPop (Stash (x : xs)) = Just (x, Stash xs)

-- | One line per entry; embedded newlines become @\\n@ (same convention as
-- the input history file).
entryToLine :: Text -> Text
entryToLine = T.replace "\\" "\\\\" . T.replace "\n" "\\n"

entryFromLine :: Text -> Text
entryFromLine = T.replace "\\n" "\n" . T.replace "\\\\" "\\"

-- | @~/.trha/state/stash.jsonl@ (legacy @~/.trha/stash.jsonl@ is read).
defaultStashPath :: IO FilePath
defaultStashPath = stateReadPath "stash.jsonl"

-- | Load the stash (missing/unreadable file = empty).
loadStash :: IO Stash
loadStash = do
  path <- defaultStashPath
  exists <- doesFileExist path
  if not exists
    then pure emptyStash
    else do
      body <- TIO.readFile path `catchIO` const (pure "")
      pure $ Stash
        [ entryFromLine line
        | line <- T.lines body
        , not (T.null line) ]

-- | Persist atomically (tmp + rename).
saveStash :: Stash -> IO ()
saveStash (Stash xs) = do
  path <- stateWritePath "stash.jsonl"
  let tmp = path ++ ".tmp"
  TIO.writeFile tmp (T.unlines (map entryToLine xs))
  renameFile tmp path `catchIO` const (pure ())

catchIO :: IO a -> (IOException -> IO a) -> IO a
catchIO action handler = do
  r <- try action
  case r of
    Left e  -> handler e
    Right a -> pure a
