{-# LANGUAGE OverloadedStrings #-}

module UI.Model
  ( -- * Model UI
    listModelsUI
  , getModelUI
  ) where

import Core.Types
import Core.Client
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO

-- | List all models
listModelsUI :: CLIClient -> IO ()
listModelsUI client = do
  result <- listModels client
  case result of
    Right models -> do
      if null models
        then putStrLn "No models found"
        else do
          putStrLn "Available models:"
          mapM_ (\m -> putStrLn $ "  - " ++ T.unpack (modelName m) ++ ": " ++ T.unpack (modelDescription m)) models
    Left err -> putStrLn $ "Error: " ++ show err

-- | Get a model
getModelUI :: CLIClient -> Text -> IO ()
getModelUI client modelNameText = do
  result <- getModel client modelNameText
  case result of
    Right model -> do
      putStrLn $ "Model: " ++ T.unpack (modelName model)
      putStrLn $ "Description: " ++ T.unpack (modelDescription model)
      putStrLn $ "Context size: " ++ show (modelContextSize model)
    Left err -> putStrLn $ "Error: " ++ show err