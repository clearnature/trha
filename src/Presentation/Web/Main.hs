{-# LANGUAGE OverloadedStrings #-}

module Presentation.Web.Main
  ( WebApp(..)
  , createWebApp
  , startWebApp
  ) where

import Data.Text (Text)

-- | Web application configuration
data WebApp = WebApp
  { webAppPort :: Int
  , webAppHost :: Text
  , webAppDevMode :: Bool
  } deriving (Show, Eq)

-- | Create a new web application
createWebApp :: Int -> Text -> Bool -> WebApp
createWebApp port host devMode = WebApp port host devMode

-- | Start the web application (placeholder)
startWebApp :: WebApp -> IO ()
startWebApp app = do
  putStrLn $ "Starting web application on " ++ show (webAppHost app) ++ ":" ++ show (webAppPort app)
  putStrLn $ "Dev mode: " ++ show (webAppDevMode app)
  -- Placeholder: in real implementation, start Warp server
  putStrLn "Web application started"