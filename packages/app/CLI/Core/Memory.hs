{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Long-term notes (@/remember@, @/memory@).
--
-- Notes live in @~/.trha/memories/@ — one Markdown file per topic — instead
-- of the single @~/.trha/memory.md@ file older builds wrote.  The legacy
-- file is still read (and labelled), so an upgrade does not lose notes; new
-- entries go to @memories/notes.md@.
module Core.Memory
  ( memoryDir
  , defaultMemoryFile
  , rememberText
  , memoryFiles
  , allMemories
  ) where

import Control.Exception (IOException, catch)
import Data.List (sort)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Directory
    ( createDirectoryIfMissing, doesDirectoryExist, doesFileExist
    , getHomeDirectory, listDirectory )
import System.FilePath ((</>))
import Core.Fs (chmodQuiet)

import Config.Settings (getConfigDir)

-- | @~/.trha/memories@.
memoryDir :: IO FilePath
memoryDir = (</> "memories") <$> getConfigDir

-- | The file @/remember@ appends to.
defaultMemoryFile :: IO FilePath
defaultMemoryFile = (</> "notes.md") <$> memoryDir

-- | Append one note to @memories/notes.md@.
rememberText :: Text -> IO ()
rememberText text = do
  dir <- memoryDir
  createDirectoryIfMissing True dir
  chmodQuiet dir 0o700
  let path = dir </> "notes.md"
  TIO.appendFile path ("- " <> T.strip text <> "\n")
  -- Notes hold whatever the user asked to remember — treat them like
  -- settings.yaml and the run logs (0600), not like a world-readable file.
  chmodQuiet path 0o600

-- | Every non-empty @*.md@ under a directory, sorted by file name.
memoryFiles :: FilePath -> IO [(Text, Text)]
memoryFiles dir = do
  ok <- doesDirectoryExist dir
  if not ok then pure [] else do
    names <- sort . filter (T.isSuffixOf ".md" . T.pack)
           <$> (listDirectory dir `catch` \(_ :: IOException) -> pure [])
    fmap concat $ mapM readOne names
  where
    readOne name = do
      body <- TIO.readFile (dir </> name) `catch` \(_ :: IOException) -> pure ""
      pure [ (T.pack name, body) | not (T.null (T.strip body)) ]

-- | Current notes plus the legacy @~/.trha/memory.md@ (if any).
allMemories :: IO [(Text, Text)]
allMemories = do
  dir <- memoryDir
  home <- getHomeDirectory
  current <- memoryFiles dir
  legacy <- legacyNote (home </> ".trha" </> "memory.md")
  pure (current ++ legacy)

legacyNote :: FilePath -> IO [(Text, Text)]
legacyNote path = do
  ok <- doesFileExist path
  if not ok then pure [] else do
    body <- TIO.readFile path `catch` \(_ :: IOException) -> pure ""
    pure [("memory.md (legacy)", body) | not (T.null (T.strip body))]
