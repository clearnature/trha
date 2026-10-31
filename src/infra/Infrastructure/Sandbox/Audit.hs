{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sandbox audit log (T1.7): one JSON object per line in
-- @~/.trha/logs/sandbox.jsonl@ (0600, rotated at 10 MiB).
module Infrastructure.Sandbox.Audit
  ( AuditKind(..)
  , AuditEvent(..)
  , auditFile
  , appendAudit
  , appendAuditAt
  , readAudit
  , readAuditAt
  ) where

import Control.Monad (when)
import Data.Aeson
  ( FromJSON(..), ToJSON(..), object, withObject, (.:), (.:?), (.=) )
import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Lazy.Char8 as BLC
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (defaultTimeLocale, formatTime, getCurrentTime)
import System.Directory
  ( createDirectoryIfMissing, doesFileExist, getFileSize, getHomeDirectory
  , removeFile, renameFile )
import System.FilePath ((</>), takeDirectory)
#ifndef mingw32_HOST_OS
import System.Posix.Files (ownerReadMode, ownerWriteMode, setFileMode, unionFileModes)
#endif

data AuditKind = AuditAllow | AuditDeny | AuditPartial | AuditError
  deriving (Eq, Show)

data AuditEvent = AuditEvent
  { aeTs          :: Text
  , aeScope       :: Text
  , aeKind        :: AuditKind
  , aeTarget      :: Text
  , aeBackend     :: Text
  , aeEnforcement :: Text
  , aeExperiment  :: Maybe Text
  } deriving (Eq, Show)

instance ToJSON AuditEvent where
  toJSON e = object $
    [ "v" .= (1 :: Int)
    , "ts" .= aeTs e
    , "scope" .= aeScope e
    , "event" .= kindText (aeKind e)
    , "target" .= aeTarget e
    , "backend" .= aeBackend e
    , "enforcement" .= aeEnforcement e
    ] ++ maybe [] (\tag -> ["experiment" .= tag]) (aeExperiment e)

instance FromJSON AuditEvent where
  parseJSON = withObject "AuditEvent" $ \o -> AuditEvent
    <$> o .: "ts"
    <*> o .: "scope"
    <*> (parseKind <$> o .: "event")
    <*> o .: "target"
    <*> o .: "backend"
    <*> o .: "enforcement"
    <*> o .:? "experiment"

kindText :: AuditKind -> Text
kindText AuditAllow = "allow"
kindText AuditDeny = "deny"
kindText AuditPartial = "partial"
kindText AuditError = "error"

parseKind :: Text -> AuditKind
parseKind "deny" = AuditDeny
parseKind "partial" = AuditPartial
parseKind "error" = AuditError
parseKind _ = AuditAllow

-- | @~/.trha/logs/sandbox.jsonl@.
auditFile :: IO FilePath
auditFile = do
  home <- getHomeDirectory
  pure (home </> ".trha" </> "logs" </> "sandbox.jsonl")

appendAudit :: AuditEvent -> IO ()
appendAudit event = auditFile >>= \path -> appendAuditAt path event

appendAuditAt :: FilePath -> AuditEvent -> IO ()
appendAuditAt path event = do
  createDirectoryIfMissing True (takeDirectory path)
  rotateAt path
  now <- getCurrentTime
  let stamped = event
        { aeTs = T.pack (formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" now) }
  BL.appendFile path (Aeson.encode stamped <> "\n")
#ifndef mingw32_HOST_OS
  setFileMode path (ownerReadMode `unionFileModes` ownerWriteMode)
#endif

readAudit :: Int -> IO [AuditEvent]
readAudit limit = auditFile >>= \path -> readAuditAt path limit

readAuditAt :: FilePath -> Int -> IO [AuditEvent]
readAuditAt path limit = do
  exists <- doesFileExist path
  if not exists
    then pure []
    else do
      content <- BL.readFile path
      let rawLines = filter (not . BL.null) (BLC.lines content)
          parsed = [ e
                   | Right e <- map Aeson.eitherDecodeStrict' (map BL.toStrict rawLines) ]
      pure (drop (max 0 (length parsed - limit)) parsed)

rotateAt :: FilePath -> IO ()
rotateAt path = do
  exists <- doesFileExist path
  when exists $ do
    size <- getFileSize path
    when (size > 10 * 1024 * 1024) $ do
      let backup = path <> ".1"
      backupExists <- doesFileExist backup
      when backupExists (removeFile backup)
      renameFile path backup
