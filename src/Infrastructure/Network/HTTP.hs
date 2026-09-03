module Infrastructure.Network.HTTP
  ( HTTPClient(..)
  , createHTTPClient
  , get
  , post
  ) where

import Data.Text (Text)
import qualified Data.Text as T

-- | HTTP client (placeholder)
data HTTPClient = HTTPClient
  { baseUrl :: Text
  }

-- | Create a new HTTP client
createHTTPClient :: Text -> IO HTTPClient
createHTTPClient url = do
  return $ HTTPClient url

-- | GET request (placeholder)
get :: HTTPClient -> Text -> IO Text
get client path = do
  return $ T.pack "GET response from " <> baseUrl client <> path

-- | POST request (placeholder)
post :: HTTPClient -> Text -> Text -> IO Text
post client path body = do
  return $ T.pack "POST response from " <> baseUrl client <> path