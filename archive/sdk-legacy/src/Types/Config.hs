{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}

module Types.Config
  ( -- * Configuration
    SDKConfig(..)
  , defaultConfig
  , loadConfig
  , saveConfig
  ) where

import Core.Types (SDKConfig(..), defaultConfig)
import Data.Aeson
import Data.Text (Text)
import qualified Data.ByteString.Lazy as BSL
import System.Directory (doesFileExist)

-- | Load configuration from file
loadConfig :: FilePath -> IO (Maybe SDKConfig)
loadConfig path = do
  exists <- doesFileExist path
  if exists
    then do
      content <- BSL.readFile path
      return $ decode content
    else return Nothing

-- | Save configuration to file
saveConfig :: FilePath -> SDKConfig -> IO ()
saveConfig path config = do
  BSL.writeFile path (encode config)