{-# LANGUAGE OverloadedStrings #-}

module Core.HTTP
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

import Core.Types
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
createHTTPClient :: Text -> Int -> IO HTTPClient
createHTTPClient host port = do
  manager <- newManager tlsManagerSettings
  let baseUrl = "http://" ++ T.unpack host ++ ":" ++ show port
  return $ HTTPClient manager baseUrl

-- | Build URL from path
buildUrl :: HTTPClient -> String -> String
buildUrl client path = httpClientBase client ++ path

-- | Parse JSON response
parseResponse :: FromJSON a => Response BSL.ByteString -> Either SDKError a
parseResponse response
  | statusIsSuccessful (responseStatus response) =
      case decode (responseBody response) of
        Just value -> Right value
        Nothing -> Left $ ValidationError "Failed to parse JSON response"
  | otherwise =
      case statusCode (responseStatus response) of
        401 -> Left $ AuthenticationError "Unauthorized"
        403 -> Left $ AuthenticationError "Forbidden"
        404 -> Left $ ServerError "Not found"
        500 -> Left $ ServerError "Internal server error"
        _   -> Left $ ServerError $ "HTTP error: " ++ T.pack (show (statusCode (responseStatus response)))

-- | HTTP GET request
httpGet :: FromJSON a => HTTPClient -> String -> IO (Either SDKError a)
httpGet client path = do
  let url = buildUrl client path
  request <- parseRequest url
  response <- httpLbs request (httpClientManager client)
  return $ parseResponse response

-- | HTTP POST request
httpPost :: (ToJSON a, FromJSON b) => HTTPClient -> String -> a -> IO (Either SDKError b)
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
httpPut :: (ToJSON a, FromJSON b) => HTTPClient -> String -> a -> IO (Either SDKError b)
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
httpDelete :: FromJSON a => HTTPClient -> String -> IO (Either SDKError a)
httpDelete client path = do
  let url = buildUrl client path
  request <- parseRequest url
  let request' = request { method = "DELETE" }
  response <- httpLbs request' (httpClientManager client)
  return $ parseResponse response