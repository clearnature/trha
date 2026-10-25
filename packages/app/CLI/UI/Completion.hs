{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | @\@@-file completion (M4-2): a bounded project index and the pure
-- query/filter/insert logic.  brick has no extmarks, so the TUI degrades
-- to "insert the path as text" (the plan's agreed fallback).
--
-- The IO half ('scanProject') walks the working tree once, skipping build
-- and VCS directories and stopping at a depth/entry budget; the pure half
-- is what the specs pin down.
module UI.Completion
  ( Completion(..)
  , IndexOptions(..)
  , defaultIndexOptions
  , buildIndex
  , completeIndex
  , completionQuery
  , applyCompletion
    -- * Popup state
  , CompletionState(..)
  , completionPopup
  , moveCompletion
  , selectedCompletion
  , applySelected
  , scanProject
  ) where

import Control.Exception (IOException, catch)
import Control.Monad (forM_, unless, when)
import Data.IORef
import Data.List (sortOn)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import System.Directory (doesDirectoryExist, listDirectory)
import System.FilePath ((</>))

-- | One candidate.  Directories are kept with a trailing slash so the
-- widget can tell them apart and completion can keep descending.
data Completion = Completion
  { compPath  :: Text
  , compIsDir :: Bool
  } deriving (Show, Eq, Ord)

-- | Budget for the index.  A huge tree must not block the input.
data IndexOptions = IndexOptions
  { ioMaxEntries :: Int   -- ^ stop after this many paths
  , ioMaxDepth   :: Int   -- ^ component depth (0 = root's children)
  , ioIgnore     :: [Text] -- ^ directory names skipped anywhere
  } deriving (Show, Eq)

defaultIndexOptions :: IndexOptions
defaultIndexOptions = IndexOptions
  { ioMaxEntries = 4000
  , ioMaxDepth   = 6
  , ioIgnore     = [ ".git", "node_modules", "dist-newstyle", ".stack-work"
                   , "__pycache__", ".venv", "target" ]
  }

-- | Turn a list of relative paths (directories ending in @/@) into the
-- index: drop ignored components, enforce the depth/entry budget, dedupe
-- and sort.
buildIndex :: IndexOptions -> [Text] -> [Completion]
buildIndex opts paths = take (ioMaxEntries opts) $ sortOn compPath $ dedupe
  [ Completion p (T.isSuffixOf "/" p)
  | raw <- paths
  , let p = T.replace "\\" "/" raw
  , not (T.null p)
  , let comps = filter (not . T.null) (T.splitOn "/" p)
  , length comps <= max 0 (ioMaxDepth opts) + 1
  , not (any (`elem` ioIgnore opts) comps)
  ]
  where
    dedupe = Set.toList . Set.fromList

-- | Filter and rank candidates for a query.  Ranking: path prefix first,
-- then basename prefix, then substring; ties broken by shorter path and
-- then alphabetically.  Case-insensitive; @limit@ caps the list.
completeIndex :: Int -> Text -> [Completion] -> [Completion]
completeIndex limit query items =
  take (max 0 limit) $ map fourth $ sortOn key scored
  where
    q = T.toLower (T.strip query)
    scored =
      [ (rank, T.length (compPath c), compPath c, c)
      | c <- items
      , Just rank <- [rankOf c]
      ]
    key (rank, len, path, _) = (rank, len, path)
    fourth (_, _, _, c) = c
    rankOf c
      | q `T.isPrefixOf` low = Just (0 :: Int)
      | q `T.isPrefixOf` base = Just 1
      | q `T.isInfixOf` low   = Just 2
      | otherwise             = Nothing
      where
        low  = T.toLower (compPath c)
        base = T.toLower (snd (T.breakOnEnd "/" low))

-- | Locate the @\@@ token that ends at the cursor.  Returns the offset of
-- the @\@@ and the query text after it.  A token must start at the
-- beginning or after whitespace, and cannot contain spaces.
completionQuery :: Text -> Int -> Maybe (Int, Text)
completionQuery text cursor
  | cursor < 1 || cursor > T.length text = Nothing
  | otherwise = go (cursor - 1)
  where
    go i
      | i < 0 = Nothing
      | c == '@' =
          if i == 0 || isSpace (T.index text (i - 1))
            then Just (i, T.take (cursor - i - 1) (T.drop (i + 1) text))
            else Nothing
      | isSpace c = Nothing
      | otherwise = go (i - 1)
      where c = T.index text i
    isSpace c = c == ' ' || c == '\n' || c == '\t'

-- | Replace @text[start..end)@ (the @\@@ token) with the chosen path.
-- Directories keep a trailing slash so the user can keep descending; files
-- are inserted as-is.
applyCompletion :: Text -> Int -> Int -> Completion -> Text
applyCompletion text start end chosen =
  T.take start text <> compPath chosen <> T.drop end text

-- | Open popup: the matching items, the token span and the selection.
data CompletionState = CompletionState
  { csItems :: [Completion]
  , csStart :: Int   -- ^ offset of the @\@@
  , csEnd   :: Int   -- ^ offset just past the query (the cursor)
  , csSel   :: Int
  } deriving (Show, Eq)

-- | Build the popup state for the current editor text and cursor.  Nothing
-- when the cursor is not inside a token or nothing matches.
completionPopup :: Int -> [Completion] -> Text -> Int -> Maybe CompletionState
completionPopup limit index text cursor = do
  (start, q) <- completionQuery text cursor
  let items = completeIndex limit q index
  if null items
    then Nothing
    else Just (CompletionState items start cursor 0)

-- | Move the popup selection (clamped).
moveCompletion :: Int -> CompletionState -> CompletionState
moveCompletion delta cs = cs
  { csSel = max 0 (min (length (csItems cs) - 1) (csSel cs + delta)) }

-- | The highlighted candidate, if any.
selectedCompletion :: CompletionState -> Maybe Completion
selectedCompletion cs = case drop (csSel cs) (csItems cs) of
  (c : _) -> Just c
  []      -> Nothing

-- | Replace the token with the highlighted candidate.
applySelected :: Text -> CompletionState -> Maybe Text
applySelected text cs =
  applyCompletion text (csStart cs) (csEnd cs) <$> selectedCompletion cs

-- | Walk @root@ and build the index.  Best effort: unreadable directories
-- are skipped, and the walk stops once the entry budget is spent.
scanProject :: IndexOptions -> FilePath -> IO [Completion]
scanProject opts root = do
  seen <- newIORef ([] :: [Text])
  let budget = ioMaxEntries opts
      walk depth dir rel = do
        done <- readIORef seen
        when (length done < budget) $ do
          names <- listDirectory dir `catch` \(_ :: IOException) -> pure []
          forM_ names $ \n -> do
            done' <- readIORef seen
            when (length done' < budget) $ do
              let rel' = if null rel then n else rel ++ "/" ++ n
              isDir <- doesDirectoryExist (dir </> n)
              if isDir
                then unless (T.pack n `elem` ioIgnore opts) $ do
                  modifyIORef' seen (T.pack (rel' ++ "/") :)
                  when (depth < ioMaxDepth opts) $ walk (depth + 1) (dir </> n) rel'
                else modifyIORef' seen (T.pack rel' :)
  walk 0 root ""
  buildIndex opts <$> readIORef seen
