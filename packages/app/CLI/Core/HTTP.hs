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
import Data.ByteString (ByteString)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.ByteString.Lazy as BSL
import Network.HTTP.Client
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Network.HTTP.Types (HeaderName)
import Network.HTTP.Types.Status

-- | HTTP client
data HTTPClient = HTTPClient
  { httpClientManager :: Manager
  , httpClientBase    :: String
  , httpClientToken   :: Text
  }

-- | Create a new HTTP client
createHTTPClient :: Text -> Int -> Text -> Int -> IO HTTPClient
createHTTPClient host port token timeoutMs = do
  manager <- newManager tlsManagerSettings
    { managerResponseTimeout = responseTimeoutMicro (timeoutMs * 1000) }
  let baseUrl = "http://" ++ T.unpack host ++ ":" ++ show port
  return $ HTTPClient manager baseUrl token

-- | Authorization header for the orchestration token.
authHeader :: HTTPClient -> [(HeaderName, ByteString)]
authHeader client = case httpClientToken client of
  t | T.null t -> []
    | otherwise -> [("Authorization", "Bearer " <> TE.encodeUtf8 t)]

-- | Build URL from path
buildUrl :: HTTPClient -> String -> String
buildUrl client path = httpClientBase client ++ path

-- | Parse JSON response
parseResponse :: FromJSON a => Response BSL.ByteString -> Either CLIError a
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
        _   -> Left $ ServerError $ T.pack $ "HTTP error: " ++ show (statusCode (responseStatus response))

-- | HTTP GET request
httpGet :: FromJSON a => HTTPClient -> String -> IO (Either CLIError a)
httpGet client path = do
  let url = buildUrl client path
  request <- parseRequest url
  let request' = request { requestHeaders = authHeader client }
  response <- httpLbs request' (httpClientManager client)
  return $ parseResponse response

-- | HTTP POST request
httpPost :: (ToJSON a, FromJSON b) => HTTPClient -> String -> a -> IO (Either CLIError b)
httpPost client path body = do
  let url = buildUrl client path
  request <- parseRequest url
  let request' = request
        { method = "POST"
        , requestBody = RequestBodyLBS (encode body)
        , requestHeaders = ("Content-Type", "application/json") : authHeader client
        }
  response <- httpLbs request' (httpClientManager client)
  return $ parseResponse response

-- | HTTP PUT request
httpPut :: (ToJSON a, FromJSON b) => HTTPClient -> String -> a -> IO (Either CLIError b)
httpPut client path body = do
  let url = buildUrl client path
  request <- parseRequest url
  let request' = request
        { method = "PUT"
        , requestBody = RequestBodyLBS (encode body)
        , requestHeaders = ("Content-Type", "application/json") : authHeader client
        }
  response <- httpLbs request' (httpClientManager client)
  return $ parseResponse response

-- | HTTP DELETE request
httpDelete :: FromJSON a => HTTPClient -> String -> IO (Either CLIError a)
httpDelete client path = do
  let url = buildUrl client path
  request <- parseRequest url
  let request' = request { method = "DELETE", requestHeaders = authHeader client }
  response <- httpLbs request' (httpClientManager client)
  return $ parseResponse response