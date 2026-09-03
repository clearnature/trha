{-# LANGUAGE OverloadedStrings #-}

module Infrastructure.Network.HTTP
  ( HTTPClient(..)
  , createHTTPClient
  , get
  , post
  , put
  , delete
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.ByteString.Lazy as BSL
import Network.HTTP.Client
import Network.HTTP.Client.TLS
import Network.HTTP.Types.Status

-- | HTTP client
data HTTPClient = HTTPClient
  { httpClientManager :: Manager
  , httpClientBase    :: Text
  }

-- | Create a new HTTP client
createHTTPClient :: Text -> IO HTTPClient
createHTTPClient url = do
  manager <- newManager tlsManagerSettings
  return $ HTTPClient manager url

-- | GET request
get :: HTTPClient -> Text -> IO (Either Text Text)
get client path = do
  let url = T.unpack (httpClientBase client) ++ T.unpack path
  request <- parseRequest url
  response <- httpLbs request (httpClientManager client)
  if statusIsSuccessful (responseStatus response)
    then return $ Right $ T.pack $ show $ responseBody response
    else return $ Left $ T.pack $ "HTTP error: " ++ show (statusCode (responseStatus response))

-- | POST request
post :: HTTPClient -> Text -> Text -> IO (Either Text Text)
post client path body = do
  let url = T.unpack (httpClientBase client) ++ T.unpack path
  request <- parseRequest url
  let request' = request
        { method = "POST"
        , requestBody = RequestBodyLBS (BSL.fromStrict $ TE.encodeUtf8 body)
        , requestHeaders = [("Content-Type", "application/json")]
        }
  response <- httpLbs request' (httpClientManager client)
  if statusIsSuccessful (responseStatus response)
    then return $ Right $ T.pack $ show $ responseBody response
    else return $ Left $ T.pack $ "HTTP error: " ++ show (statusCode (responseStatus response))

-- | PUT request
put :: HTTPClient -> Text -> Text -> IO (Either Text Text)
put client path body = do
  let url = T.unpack (httpClientBase client) ++ T.unpack path
  request <- parseRequest url
  let request' = request
        { method = "PUT"
        , requestBody = RequestBodyLBS (BSL.fromStrict $ TE.encodeUtf8 body)
        , requestHeaders = [("Content-Type", "application/json")]
        }
  response <- httpLbs request' (httpClientManager client)
  if statusIsSuccessful (responseStatus response)
    then return $ Right $ T.pack $ show $ responseBody response
    else return $ Left $ T.pack $ "HTTP error: " ++ show (statusCode (responseStatus response))

-- | DELETE request
delete :: HTTPClient -> Text -> IO (Either Text Text)
delete client path = do
  let url = T.unpack (httpClientBase client) ++ T.unpack path
  request <- parseRequest url
  let request' = request { method = "DELETE" }
  response <- httpLbs request' (httpClientManager client)
  if statusIsSuccessful (responseStatus response)
    then return $ Right $ T.pack $ show $ responseBody response
    else return $ Left $ T.pack $ "HTTP error: " ++ show (statusCode (responseStatus response))