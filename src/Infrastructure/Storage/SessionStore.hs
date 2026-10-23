{-# LANGUAGE ScopedTypeVariables #-}

-- | Directory-backed store for session snapshots.
--
-- Kept generic over the payload (@ToJSON a / FromJSON a@) on purpose: this
-- library shares @src/@ as its source root, so importing a concrete type from
-- @trha-core@ would make cabal recompile that module inside this component
-- (and the resulting type would not be identical to @trha-core@'s). The
-- caller (trha-api) supplies the concrete snapshot type.
--
-- One JSON file per session, written atomically (tmp + rename). Missing
-- directory or corrupt file degrades to \"no snapshot\".
module Infrastructure.Storage.SessionStore
  ( snapshotPath
  , saveSessionSnapshot
  , loadSessionSnapshot
  , listSessionSnapshots
  , deleteSessionSnapshot
  ) where

import Control.Exception (IOException, SomeException, catch, try)
import Control.Monad (forM)
import Data.Aeson (FromJSON, ToJSON, decode, encode)
import qualified Data.ByteString.Lazy as BL
import Data.Char (isAlphaNum)
import System.Directory
import System.FilePath ((</>), takeExtension)

-- | Keep host-supplied ids file-safe.
safeName :: String -> String
safeName = map (\c -> if isAlphaNum c || c `elem` "._-" then c else '_')

snapshotPath :: FilePath -> String -> FilePath
snapshotPath dir sid = dir </> (safeName sid ++ ".json")

saveSessionSnapshot :: ToJSON a => FilePath -> String -> a -> IO ()
saveSessionSnapshot dir sid value = do
  createDirectoryIfMissing True dir
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
  exists <- doesDirectoryExist dir
  if not exists
    then pure []
    else do
      names <- listDirectory dir
      fmap concat $ forM [n | n <- names, takeExtension n == ".json"] $ \n -> do
        r <- try (BL.readFile (dir </> n)) :: IO (Either SomeException BL.ByteString)
        pure $ case r of
          Left _   -> []
          Right bs -> maybe [] pure (decode bs)

deleteSessionSnapshot :: FilePath -> String -> IO ()
deleteSessionSnapshot dir sid =
  removeFile (snapshotPath dir sid) `catch` \(_ :: IOException) -> pure ()
