{-# LANGUAGE OverloadedStrings #-}

-- | Multi-line input history for the TUI, shared with the REPL's
-- haskeline history file (@~\/.trha\/history@): the TUI loads it at
-- startup and appends submitted entries, so both shells see one history.
--
-- The file is line-oriented (one entry per line, oldest first).  TUI
-- entries may span lines, so stored entries escape newlines as
-- backslash-n; a literal backslash-n typed by the user therefore
-- round-trips as a newline on load (accepted M1 trade-off).
module UI.InputHistory
  ( HistState(..)
  , emptyHistState
  , maxHistEntries
  , histUp
  , histDown
  , histCommit
  , entryToLine
  , entryFromLine
  , historyEntriesFromLines
  , defaultHistoryPath
  , loadHistory
  , appendHistory
  ) where

import Control.Exception (IOException, try)
import Control.Monad (void)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Directory (doesFileExist, getHomeDirectory)
import System.FilePath ((</>))

-- | Input history state.  @hsHistory@ is newest-first (front = the most
-- recently submitted entry); @hsIndex@ is the position while navigating
-- ('Nothing' = not navigating); @hsDraft@ is the in-progress input
-- stashed when navigation starts.
data HistState = HistState
  { hsHistory :: [Text]
  , hsIndex   :: Maybe Int
  , hsDraft   :: Maybe Text
  } deriving (Show, Eq)

emptyHistState :: HistState
emptyHistState = HistState [] Nothing Nothing

-- | History recall cap, both for loading and for committing.
maxHistEntries :: Int
maxHistEntries = 100

-- | ↑: show the previous (older) entry.  The first navigation step
-- stashes the current input as the draft.  'Nothing' means there is
-- nothing older to show and the editor should keep its state.
histUp :: Text -> HistState -> Maybe (HistState, Text)
histUp cur hs =
  let idx = maybe 0 succ (hsIndex hs)
  in case drop idx (hsHistory hs) of
       [] -> Nothing
       (e : _) ->
         let draft = case hsIndex hs of
               Nothing -> Just cur
               Just _  -> hsDraft hs
         in Just (HistState (hsHistory hs) (Just idx) draft, e)

-- | ↓: show the next (newer) entry, or restore the draft when moving
-- past the newest.  'Nothing' when not navigating.
histDown :: HistState -> Maybe (HistState, Text)
histDown hs = case hsIndex hs of
  Nothing -> Nothing
  Just 0 ->
    Just (HistState (hsHistory hs) Nothing Nothing, fromMaybe "" (hsDraft hs))
  Just i -> case drop (i - 1) (hsHistory hs) of
    (e : _) -> Just (HistState (hsHistory hs) (Just (i - 1)) (hsDraft hs), e)
    []      -> Nothing

-- | Commit a submitted entry: push it to the front (suppressing an
-- immediate duplicate), cap the length, and clear navigation state.
histCommit :: Text -> HistState -> HistState
histCommit entry hs
  | T.null entry = hs { hsIndex = Nothing, hsDraft = Nothing }
  | otherwise =
      HistState (dedupFront entry (hsHistory hs)) Nothing Nothing
  where
    dedupFront e (x : xs) | x == e = x : xs
    dedupFront e xs = e : take (maxHistEntries - 1) xs

-- | Escape newlines so a multi-line entry fits one history-file line.
entryToLine :: Text -> Text
entryToLine = T.replace "\n" "\\n"

-- | Restore newlines escaped by 'entryToLine'.
entryFromLine :: Text -> Text
entryFromLine = T.replace "\\n" "\n"

-- | Parse file lines (oldest first) into entries (newest first).
historyEntriesFromLines :: [Text] -> [Text]
historyEntriesFromLines ls =
  take maxHistEntries
    (reverse (map entryFromLine (filter (not . T.null) ls)))

-- | The shared REPL history file path (@~\/.trha\/history@).
defaultHistoryPath :: IO FilePath
defaultHistoryPath = do
  home <- getHomeDirectory
  return (home </> ".trha" </> "history")

-- | Load the shared history file; best effort — a missing or unreadable
-- file yields an empty history.
loadHistory :: IO HistState
loadHistory = do
  contents <- (try :: IO Text -> IO (Either IOException Text)) $ do
    path <- defaultHistoryPath
    ok <- doesFileExist path
    if ok then TIO.readFile path else return T.empty
  let entries = either (const [])
                  (historyEntriesFromLines . T.lines) contents
  return emptyHistState { hsHistory = entries }

-- | Append a submitted entry to the shared file; best effort, IO errors
-- are ignored.
appendHistory :: Text -> IO ()
appendHistory entry = void $ (try :: IO () -> IO (Either IOException ())) $ do
  path <- defaultHistoryPath
  TIO.appendFile path (entryToLine entry <> "\n")
