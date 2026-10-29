{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Disk cache for the @\@@-file completion index (@~/.trha/cache@).
--
-- The TUI walks the project once at startup to build the @\@@-completion
-- index.  On a large tree that walk is wasted work on every launch, so the
-- result is cached per workspace and reused while it is still fresh:
--
--   * the cache belongs to one root (the absolute workspace path);
--   * it expires after 'cacheTtlSeconds';
--   * a changed root-directory mtime invalidates it immediately (files added
--     or removed at the top level show up without waiting for the TTL).
--
-- A missing/corrupt cache is never fatal: it just means "scan again".
module UI.IndexCache
  ( scanProjectCached
  , isFresh
  , indexCachePath
  , fnv1a
  , cacheTtlSeconds
  , CacheFile(..)
  , CachedFile(..)
  ) where

import Control.Exception (IOException, catch)
import Data.Aeson (FromJSON, ToJSON, decode, encode)
import Data.Bits (xor)
import qualified Data.ByteString.Lazy as BL
import Data.Char (ord)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (UTCTime, diffUTCTime, getCurrentTime)
import Data.Word (Word32)
import GHC.Generics (Generic)
import Numeric (showHex)
import System.Directory
    ( createDirectoryIfMissing, doesFileExist, getModificationTime )
import System.FilePath ((</>))
import Core.Fs (chmodQuiet)

import Config.Settings (getConfigDir)
import UI.Completion (Completion(..), IndexOptions, scanProject)

-- | How long a cached index stays usable (seconds).
cacheTtlSeconds :: Int
cacheTtlSeconds = 600

-- | One index entry on disk.
data CachedFile = CachedFile
  { cfPath :: Text
  , cfDir  :: Bool
  } deriving (Show, Eq, Generic)

instance ToJSON CachedFile
instance FromJSON CachedFile

data CacheFile = CacheFile
  { cfeRoot      :: FilePath
  , cfeScannedAt :: UTCTime
  , cfeRootMtime :: UTCTime
  , cfeFiles     :: [CachedFile]
  } deriving (Show, Eq, Generic)

instance ToJSON CacheFile
instance FromJSON CacheFile

-- | @~/.trha/cache/index-<fnv>.json@.
indexCachePath :: FilePath -> IO FilePath
indexCachePath root = do
  dir <- (</> "cache") <$> getConfigDir
  pure (dir </> ("index-" <> showHex (fnv1a (T.pack root)) "" <> ".json"))

-- | FNV-1a (32-bit) over the path, so the file name stays short and stable.
fnv1a :: Text -> Word32
fnv1a = T.foldl' step 2166136261
  where
    step h c = (h `xor` fromIntegral (ord c)) * 16777619

-- | Whether a cached entry may be reused.
isFresh :: UTCTime -> UTCTime -> CacheFile -> Bool
isFresh now rootMtime entry =
  diffUTCTime now (cfeScannedAt entry) <= fromIntegral cacheTtlSeconds
    && abs (diffUTCTime rootMtime (cfeRootMtime entry)) < 1

-- | Return the cached index when it is still valid, otherwise scan the
-- project and refresh the cache.
scanProjectCached :: IndexOptions -> FilePath -> IO [Completion]
scanProjectCached opts root = do
  now <- getCurrentTime
  mtime <- getModificationTime root `catch` \(_ :: IOException) -> pure now
  cached <- readCache root
  case cached of
    Just entry | isFresh now mtime entry ->
      pure (map toCompletion (cfeFiles entry))
    _ -> do
      files <- scanProject opts root
      writeCache root now mtime files
      pure files

readCache :: FilePath -> IO (Maybe CacheFile)
readCache root = do
  path <- indexCachePath root
  ok <- doesFileExist path
  if not ok then pure Nothing else do
    raw <- BL.readFile path `catch` \(_ :: IOException) -> pure BL.empty
    pure $ case decode raw of
      Just entry | cfeRoot entry == root -> Just entry
      _ -> Nothing

writeCache :: FilePath -> UTCTime -> UTCTime -> [Completion] -> IO ()
writeCache root now mtime files = do
  path <- indexCachePath root
  dir <- (</> "cache") <$> getConfigDir
  createDirectoryIfMissing True dir
  chmodQuiet dir 0o700
  BL.writeFile path (encode (CacheFile root now mtime (map fromCompletion files)))
    `catch` \(_ :: IOException) -> pure ()

toCompletion :: CachedFile -> Completion
toCompletion f = Completion (cfPath f) (cfDir f)

fromCompletion :: Completion -> CachedFile
fromCompletion c = CachedFile (compPath c) (compIsDir c)
