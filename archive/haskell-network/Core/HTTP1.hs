{-# LANGUAGE OverloadedStrings #-}

module Core.HTTP1
  ( -- * HTTP/1.1
    HTTP1Config(..)
  , createHTTP1Config
  
    -- * Request
  , HTTP1Request(..)
  , createHTTP1Request
  
    -- * Response
  , HTTP1Response(..)
  , createHTTP1Response
  
    -- * Methods
  , http1Get
  , http1Post
  , http1Put
  , http1Delete
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BSL

-- | HTTP/1.1 configuration
data HTTP1Config = HTTP1Config
  { http1Host :: String
  , http1Port :: Int
  }

-- | Create a new HTTP/1.1 configuration
createHTTP1Config :: String -> Int -> HTTP1Config
createHTTP1Config host port = HTTP1Config host port

-- | HTTP/1.1 request
data HTTP1Request = HTTP1Request
  { http1Method :: Text
  , http1Path :: Text
  , http1Headers :: [(Text, Text)]
  , http1Body :: BSL.ByteString
  }

-- | Create a new HTTP/1.1 request
createHTTP1Request :: Text -> Text -> [(Text, Text)] -> BSL.ByteString -> HTTP1Request
createHTTP1Request method path headers body = HTTP1Request method path headers body

-- | HTTP/1.1 response
data HTTP1Response = HTTP1Response
  { http1StatusCode :: Int
  , http1StatusMessage :: Text
  , http1ResponseHeaders :: [(Text, Text)]
  , http1ResponseBody :: BSL.ByteString
  }

-- | Create a new HTTP/1.1 response
createHTTP1Response :: Int -> Text -> [(Text, Text)] -> BSL.ByteString -> HTTP1Response
createHTTP1Response statusCode statusMessage headers body = 
    HTTP1Response statusCode statusMessage headers body

-- | HTTP/1.1 GET request
http1Get :: HTTP1Config -> Text -> IO HTTP1Response
http1Get config path = do
    -- Placeholder: implement HTTP/1.1 GET
    return $ createHTTP1Response 200 "OK" [] "GET response"

-- | HTTP/1.1 POST request
http1Post :: HTTP1Config -> Text -> BSL.ByteString -> IO HTTP1Response
http1Post config path body = do
    -- Placeholder: implement HTTP/1.1 POST
    return $ createHTTP1Response 200 "OK" [] "POST response"

-- | HTTP/1.1 PUT request
http1Put :: HTTP1Config -> Text -> BSL.ByteString -> IO HTTP1Response
http1Put config path body = do
    -- Placeholder: implement HTTP/1.1 PUT
    return $ createHTTP1Response 200 "OK" [] "PUT response"

-- | HTTP/1.1 DELETE request
http1Delete :: HTTP1Config -> Text -> IO HTTP1Response
http1Delete config path = do
    -- Placeholder: implement HTTP/1.1 DELETE
    return $ createHTTP1Response 200 "OK" [] "DELETE response"