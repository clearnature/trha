{-# LANGUAGE OverloadedStrings #-}

module Config.Settings
  ( -- * Settings
    loadConfig
  , saveConfig
  , getConfigPath
  ) where

import Core.Types
import Data.Aeson
import Data.Text (Text)
import qualified Data.ByteString.Lazy as BSL
import System.Directory (doesFileExist, getHomeDirectory)
import System.FilePath ((</>))

-- | Load configuration from file
loadConfig :: IO (Maybe CLIConfig)
loadConfig = do
  path <- getConfigPath
  exists <- doesFileExist path
  if exists
    then do
      content <- BSL.readFile path
      return $ decode content
    else return Nothing

-- | Save configuration to file
saveConfig :: CLIConfig -> IO ()
saveConfig config = do
  path <- getConfigPath
  BSL.writeFile path (encode config)

-- | Get configuration file path
getConfigPath :: IO FilePath
getConfigPath = do
  home <- getHomeDirectory
  return $ home </> ".trha" </> "config.json"