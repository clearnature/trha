{-# LANGUAGE OverloadedStrings #-}

module Infrastructure.Storage.JSON
  ( JSONStorage(..)
  , createJSONStorage
  , save
  , load
  ) where

import Data.Aeson
import qualified Data.ByteString.Lazy as BSL
import System.Directory (doesFileExist)

-- | JSON file storage
data JSONStorage = JSONStorage
  { storagePath :: FilePath
  }

-- | Create a new JSON storage
createJSONStorage :: FilePath -> IO JSONStorage
createJSONStorage path = do
  return $ JSONStorage path

-- | Save a value to JSON file
save :: ToJSON a => JSONStorage -> a -> IO ()
save storage val = do
  BSL.writeFile (storagePath storage) (encode val)

-- | Load a value from JSON file
load :: FromJSON a => JSONStorage -> IO (Maybe a)
load storage = do
  exists <- doesFileExist (storagePath storage)
  if exists
    then do
      content <- BSL.readFile (storagePath storage)
      return $ decode content
    else return Nothing