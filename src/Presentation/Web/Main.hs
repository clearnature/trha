{-# LANGUAGE OverloadedStrings #-}

module Presentation.Web.Main
  ( WebApp(..)
  , createWebApp
  , startWebApp
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Network.Wai
import Network.Wai.Handler.Warp
import Network.HTTP.Types

-- | Web application configuration
data WebApp = WebApp
  { webAppPort :: Int
  , webAppHost :: Text
  , webAppDevMode :: Bool
  } deriving (Show, Eq)

-- | Create a new web application
createWebApp :: Int -> Text -> Bool -> WebApp
createWebApp port host devMode = WebApp port host devMode

-- | Start the web application
startWebApp :: WebApp -> IO ()
startWebApp app = do
  putStrLn $ "Starting web application on " ++ T.unpack (webAppHost app) ++ ":" ++ show (webAppPort app)
  putStrLn $ "Dev mode: " ++ show (webAppDevMode app)
  
  -- Start Warp server
  let settings = setPort (webAppPort app)
               $ setHost (fromString $ T.unpack (webAppHost app))
               $ defaultSettings
  
  runSettings settings application
  where
    application :: Application
    application request respond = do
      respond $ responseLBS
        status200
        [("Content-Type", "text/plain")]
        "trha Web Application"