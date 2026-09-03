{-# LANGUAGE OverloadedStrings #-}

module Core.Warp
  ( -- * Warp Server
    WarpServer(..)
  , createWarpServer
  , startWarpServer
  , stopWarpServer
  
    -- * Application
  , Application
  , Request
  , Response
  
    -- * Helpers
  , responseLBS
  , response200
  , response404
  , response500
  ) where

import Network.Wai
import Network.Wai.Handler.Warp
import Network.HTTP.Types
import Data.String (fromString)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.ByteString.Lazy as BSL

-- | Warp server
data WarpServer = WarpServer
  { warpPort :: Int
  , warpHost :: String
  }

-- | Create a new Warp server
createWarpServer :: Int -> String -> WarpServer
createWarpServer port host = WarpServer port host

-- | Start the Warp server
startWarpServer :: WarpServer -> Application -> IO ()
startWarpServer server app = do
    putStrLn $ "Starting Warp server on " ++ warpHost server ++ ":" ++ show (warpPort server)
    runSettings settings app
  where
    settings = setPort (warpPort server)
             $ setHost (fromString (warpHost server))
             $ defaultSettings
    fromString = Data.String.fromString

-- | Stop the Warp server
stopWarpServer :: WarpServer -> IO ()
stopWarpServer server = do
    putStrLn $ "Stopping Warp server on port " ++ show (warpPort server)

-- | Create a 200 response
response200 :: BSL.ByteString -> Response
response200 body = responseLBS
    status200
    [("Content-Type", "text/plain")]
    body

-- | Create a 404 response
response404 :: Response
response404 = responseLBS
    status404
    [("Content-Type", "text/plain")]
    "Not Found"

-- | Create a 500 response
response500 :: Response
response500 = responseLBS
    status500
    [("Content-Type", "text/plain")]
    "Internal Server Error"