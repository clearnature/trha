{-# LANGUAGE OverloadedStrings #-}

module App.HTTP
  ( -- * HTTP Application
    HTTPApp(..)
  , createHTTPApp
  , runHTTPApp
  
    -- * Handlers
  , homeHandler
  , apiHandler
  , healthHandler
  ) where

import Network.Wai
import Network.HTTP.Types
import Core.Warp
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.ByteString.Lazy as BSL

-- | HTTP application
data HTTPApp = HTTPApp
  { httpAppPort :: Int
  , httpAppHost :: String
  }

-- | Create a new HTTP application
createHTTPApp :: Int -> String -> HTTPApp
createHTTPApp port host = HTTPApp port host

-- | Run the HTTP application
runHTTPApp :: HTTPApp -> IO ()
runHTTPApp app = do
    let server = createWarpServer (httpAppPort app) (httpAppHost app)
    startWarpServer server application
  where
    application :: Application
    application request respond = do
        case pathInfo request of
            [] -> homeHandler request respond
            ["api"] -> apiHandler request respond
            ["health"] -> healthHandler request respond
            _ -> respond response404

-- | Home handler
homeHandler :: Application
homeHandler request respond = do
    respond $ response200 "Welcome to trha HTTP server"

-- | API handler
apiHandler :: Application
apiHandler request respond = do
    respond $ response200 "API endpoint"

-- | Health handler
healthHandler :: Application
healthHandler request respond = do
    respond $ response200 "OK"