{-# LANGUAGE ScopedTypeVariables #-}

-- | Directory-backed store for kernel session state: a checkpoint per session
-- plus its event log.
--
-- Kept generic over the payload (@ToJSON a / FromJSON a@) on purpose: this
-- library shares @src/@ as its source root, so importing a concrete type from
-- @trha-core@ would make cabal recompile that module inside this component
-- (and the resulting type would not be identical to @trha-core@'s). The
-- caller (trha-api) supplies the concrete types.
--
-- The checkpoint is one JSON file, written atomically (tmp + rename). The
-- event log is one JSON object per line, appended in place. Missing directory
-- or corrupt file degrades to \"nothing stored\" rather than failing a request.
module Infrastructure.Storage.SessionStore
  ( snapshotPath
  , saveSessionSnapshot
  , loadSessionSnapshot
  , listSessionSnapshots
  , deleteSessionSnapshot
  , eventLogPath
  , appendEventRecords
  , loadEventRecords
  , deleteEventLog
  ) where

import Control.Exception (IOException, SomeException, catch, try)
import Control.Monad (forM)
import Data.Aeson (FromJSON, ToJSON, decode, encode)
import qualified Data.ByteString.Char8 as BS
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Lazy.Char8 as BLC
import Data.Char (isAlphaNum)
import Data.Maybe (mapMaybe)
import System.Directory
import System.FilePath ((</>), takeExtension)
import System.IO (IOMode (ReadMode), SeekMode (AbsoluteSeek), hSeek, withFile)

-- | Keep host-supplied ids file-safe.
safeName :: String -> String
safeName = map (\c -> if isAlphaNum c || c `elem` "._-" then c else '_')

-- | Session state lives in a subdirectory of the state directory.
--
-- The host's state directory is shared: the scheduler keeps one JSON file per
-- session there, named after the session id
-- (packages/scheduler/src/Server/stateStore.ts), and those are the *same* ids
-- and file names this store would use. Writing at the top level would make the
-- two stores overwrite each other for every session, losing whichever half was
-- written first. Each side therefore keeps its own namespace.
storeDir :: FilePath -> FilePath
storeDir dir = dir </> "kernel"

snapshotPath :: FilePath -> String -> FilePath
snapshotPath dir sid = storeDir dir </> (safeName sid ++ ".json")

saveSessionSnapshot :: ToJSON a => FilePath -> String -> a -> IO ()
saveSessionSnapshot dir sid value = do
  createDirectoryIfMissing True (storeDir dir)
  let target = snapshotPath dir sid
      tmp = target ++ ".tmp"
  BL.writeFile tmp (encode value)
  renameFile tmp target

loadSessionSnapshot :: FromJSON a => FilePath -> String -> IO (Maybe a)
loadSessionSnapshot dir sid = do
  let file = snapshotPath dir sid
  exists <- doesFileExist file
  if not exists
    then pure Nothing
    else do
      r <- try (BL.readFile file) :: IO (Either SomeException BL.ByteString)
      pure $ either (const Nothing) decode r

listSessionSnapshots :: FromJSON a => FilePath -> IO [a]
listSessionSnapshots dir = do
  let here = storeDir dir
  exists <- doesDirectoryExist here
  if not exists
    then pure []
    else do
      names <- listDirectory here
      fmap concat $ forM [n | n <- names, takeExtension n == ".json"] $ \n -> do
        r <- try (BL.readFile (here </> n)) :: IO (Either SomeException BL.ByteString)
        pure $ case r of
          Left _   -> []
          Right bs -> maybe [] pure (decode bs)

deleteSessionSnapshot :: FilePath -> String -> IO ()
deleteSessionSnapshot dir sid =
  removeFile (snapshotPath dir sid) `catch` \(_ :: IOException) -> pure ()

--------------------------------------------------------------------------------
-- Event log
--------------------------------------------------------------------------------

-- | The event log is one JSON object per line (@.jsonl@), appended in place.
--
-- Appending instead of rewriting the array keeps a step O(1) in the length of
-- the history, and it bounds what a crash can damage to the last line.
eventLogPath :: FilePath -> String -> FilePath
eventLogPath dir sid = storeDir dir </> (safeName sid ++ ".events.jsonl")

-- | Append records to a session's log.
--
-- If a previous write was torn mid-line, a newline goes in first: the fragment
-- then stays its own (undecodable, loader-skipped) line instead of being glued
-- onto the front of the next record.
appendEventRecords :: ToJSON a => FilePath -> String -> [a] -> IO ()
appendEventRecords _ _ [] = pure ()
appendEventRecords dir sid values = do
  createDirectoryIfMissing True (storeDir dir)
  let file = eventLogPath dir sid
      body = BL.concat [encode v <> BLC.pack "\n" | v <- values]
  torn <- endsWithPartialLine file
  BL.appendFile file (if torn then BLC.pack "\n" <> body else body)

-- | Whether the file exists, is non-empty, and does not end with a newline —
-- i.e. the last write was cut short.
endsWithPartialLine :: FilePath -> IO Bool
endsWithPartialLine file = do
  exists <- doesFileExist file
  if not exists
    then pure False
    else do
      size <- getFileSize file
      if size == 0
        then pure False
        else withFile file ReadMode $ \h -> do
          hSeek h AbsoluteSeek (size - 1)
          lastByte <- BS.hGet h 1
          pure (lastByte /= BS.pack "\n")

-- | Read a session's log, oldest first.
--
-- Undecodable lines are skipped: a crash can leave a partial last line, and
-- one bad line must not cost the whole history.
loadEventRecords :: FromJSON a => FilePath -> String -> IO [a]
loadEventRecords dir sid = do
  let file = eventLogPath dir sid
  exists <- doesFileExist file
  if not exists
    then pure []
    else do
      r <- try (BL.readFile file) :: IO (Either SomeException BL.ByteString)
      pure $ case r of
        Left _   -> []
        Right bs -> mapMaybe decode (filter (not . BLC.null) (BLC.lines bs))

deleteEventLog :: FilePath -> String -> IO ()
deleteEventLog dir sid =
  removeFile (eventLogPath dir sid) `catch` \(_ :: IOException) -> pure ()
