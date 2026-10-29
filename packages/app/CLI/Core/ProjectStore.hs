{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Per-workspace index under @~/.trha/projects/@.
--
-- One directory per working tree, named after the absolute path the way
-- Claude Code does (@/home/u/proj@ → @-home-u-proj@).  It holds an index only
-- — @meta.json@ and @sessions.json@ — while the transcript itself stays in
-- @~/.trha/sessions/<id>/transcript.jsonl@ (single source of truth, no
-- double write).
module Core.ProjectStore
  ( ProjectMeta(..)
  , ProjectSession(..)
  , projectSlug
  , projectDir
  , ensureProject
  , recordProjectSession
  , projectSessions
  ) where

import Control.Exception (IOException, catch, evaluate)
import Data.Aeson (FromJSON, ToJSON, decode, encode)
import qualified Data.ByteString.Lazy as BL
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import GHC.Generics (Generic)
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath ((</>))
import Core.Fs (chmodQuiet)

import Config.Settings (getConfigDir)
import Core.SessionSummary (SessionSummary(..))

-- | @meta.json@: what this project is and when it was last used.
data ProjectMeta = ProjectMeta
  { pmRoot         :: Text
  , pmLastSession  :: Maybe Text
  , pmUpdatedAt    :: Text
  , pmSessionCount :: Int
  } deriving (Show, Eq, Generic)

instance ToJSON ProjectMeta
instance FromJSON ProjectMeta

-- | One row of @sessions.json@.
data ProjectSession = ProjectSession
  { psId         :: Text
  , psTitle      :: Text
  , psUpdatedAt  :: Text
  , psTranscript :: Text   -- ^ path relative to @~/.trha@
  } deriving (Show, Eq, Generic)

instance ToJSON ProjectSession
instance FromJSON ProjectSession

-- | @/home/u/proj@ → @-home-u-proj@ (the rule Claude Code uses).
projectSlug :: FilePath -> Text
projectSlug = T.replace "/" "-" . T.pack

-- | @~/.trha/projects/<slug>@.
projectDir :: FilePath -> IO FilePath
projectDir root = do
  base <- getConfigDir
  pure (base </> "projects" </> T.unpack (projectSlug root))

-- | Create the project directory and refresh @meta.json@ (best effort).
ensureProject :: FilePath -> IO ()
ensureProject root = do
  dir <- projectDir root
  createDirectoryIfMissing True dir
  chmodQuiet dir 0o700
  old <- readJson (dir </> "meta.json") :: IO (Maybe ProjectMeta)
  sessions <- projectSessions root
  now <- timestamp
  writeJson (dir </> "meta.json") ProjectMeta
    { pmRoot = T.pack root
    , pmLastSession = old >>= pmLastSession
    , pmUpdatedAt = now
    , pmSessionCount = length sessions
    }

-- | Insert or update one session row and refresh @meta.json@.
recordProjectSession :: FilePath -> SessionSummary -> IO ()
recordProjectSession root s = do
  dir <- projectDir root
  createDirectoryIfMissing True dir
  chmodQuiet dir 0o700
  existing <- projectSessions root
  now <- timestamp
  let row = ProjectSession
        { psId = T.pack (ssId s)
        , psTitle = ssTitle s
        , psUpdatedAt = maybe now id (ssLastTs s)
        , psTranscript = T.pack ("sessions/" <> ssId s <> "/transcript.jsonl")
        }
      updated = case break ((== psId row) . psId) existing of
        (before, _ : after) -> before ++ [row] ++ after
        _                   -> existing ++ [row]
  writeJson (dir </> "sessions.json") updated
  old <- readJson (dir </> "meta.json") :: IO (Maybe ProjectMeta)
  writeJson (dir </> "meta.json") ProjectMeta
    { pmRoot = T.pack root
    , pmLastSession = Just (psId row)
    , pmUpdatedAt = now
    , pmSessionCount = length updated
    }

-- | Every indexed session of a project (empty when the index is missing).
projectSessions :: FilePath -> IO [ProjectSession]
projectSessions root = do
  dir <- projectDir root
  found <- readJson (dir </> "sessions.json") :: IO (Maybe [ProjectSession])
  pure (maybe [] id found)

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

timestamp :: IO Text
timestamp = T.pack <$> formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" <$> getCurrentTime

readJson :: FromJSON a => FilePath -> IO (Maybe a)
readJson path = do
  ok <- doesFileExist path
  if not ok then pure Nothing else do
    raw <- BL.readFile path `catch` \(_ :: IOException) -> pure BL.empty
    pure (decode raw)

writeJson :: ToJSON a => FilePath -> a -> IO ()
writeJson path value = do
  -- Force the encoding before the file is opened: a lazy payload evaluated
  -- while the handle is open can observe the truncated file.
  let bytes = encode value
  _ <- evaluate (BL.length bytes)
  BL.writeFile path bytes `catch` \(_ :: IOException) -> pure ()
