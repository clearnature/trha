{-# LANGUAGE OverloadedStrings #-}

module HTTP.Client
  ( -- * HTTP Client
    HTTPClient(..)
  , createHTTPClient
  
    -- * HTTP Methods
  , httpGet
  , httpPost
  , httpPut
  , httpDelete
  
    -- * Helpers
  , buildUrl
  , parseResponse
  ) where

import Data.Aeson
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.ByteString.Lazy as BSL
import Network.HTTP.Client
import Network.HTTP.Client.TLS
import Network.HTTP.Types.Status

-- | HTTP client
data HTTPClient = HTTPClient
  { httpClientManager :: Manager
  , httpClientBase    :: String
  }

-- | Create a new HTTP client
createHTTPClient :: String -> IO HTTPClient
createHTTPClient baseUrl = do
  manager <- newManager tlsManagerSettings
  return $ HTTPClient manager baseUrl

-- | Build URL from path
buildUrl :: HTTPClient -> String -> String
buildUrl client path = httpClientBase client ++ path

-- | Parse JSON response
parseResponse :: FromJSON a => Response BSL.ByteString -> Either String a
parseResponse response
  | statusIsSuccessful (responseStatus response) =
      case decode (responseBody response) of
        Just value -> Right value
        Nothing -> Left "Failed to parse JSON response"
  | otherwise =
      Left $ "HTTP error: " ++ show (statusCode (responseStatus response))

-- | HTTP GET request
httpGet :: FromJSON a => HTTPClient -> String -> IO (Either String a)
httpGet client path = do
  let url = buildUrl client path
  request <- parseRequest url
  response <- httpLbs request (httpClientManager client)
  return $ parseResponse response

-- | HTTP POST request
httpPost :: (ToJSON a, FromJSON b) => HTTPClient -> String -> a -> IO (Either String b)
httpPost client path body = do
  let url = buildUrl client path
  request <- parseRequest url
  let request' = request
        { method = "POST"
        , requestBody = RequestBodyLBS (encode body)
        , requestHeaders = [("Content-Type", "application/json")]
        }
  response <- httpLbs request' (httpClientManager client)
  return $ parseResponse response

-- | HTTP PUT request
httpPut :: (ToJSON a, FromJSON b) => HTTPClient -> String -> a -> IO (Either String b)
httpPut client path body = do
  let url = buildUrl client path
  request <- parseRequest url
  let request' = request
        { method = "PUT"
        , requestBody = RequestBodyLBS (encode body)
        , requestHeaders = [("Content-Type", "application/json")]
        }
  response <- httpLbs request' (httpClientManager client)
  return $ parseResponse response

-- | HTTP DELETE request
httpDelete :: FromJSON a => HTTPClient -> String -> IO (Either String a)
httpDelete client path = do
  let url = buildUrl client path
  request <- parseRequest url
  let request' = request { method = "DELETE" }
  response <- httpLbs request' (httpClientManager client)
  return $ parseResponse response