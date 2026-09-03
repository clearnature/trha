{-# LANGUAGE OverloadedStrings #-}

module Core.Protocol
  ( -- * Protocol Handler
    ProtocolHandler(..)
  , createProtocolHandler
  
    -- * Protocol Operations
  , serializeProtocol
  , deserializeProtocol
  , encodeJSON
  , decodeJSON
  ) where

import Data.Aeson
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.ByteString.Lazy as BSL

-- | Protocol handler
data ProtocolHandler = ProtocolHandler
  { handlerFormat :: String
  }

-- | Create a new protocol handler
createProtocolHandler :: String -> IO ProtocolHandler
createProtocolHandler format = do
  return $ ProtocolHandler format

-- | Serialize data
serializeProtocol :: ToJSON a => ProtocolHandler -> a -> IO (Either String BSL.ByteString)
serializeProtocol handler data_ = do
  case handlerFormat handler of
    "json" -> return $ Right $ encodeJSON data_
    _ -> return $ Left $ "Unsupported format: " ++ handlerFormat handler

-- | Deserialize data
deserializeProtocol :: FromJSON a => ProtocolHandler -> BSL.ByteString -> IO (Either String a)
deserializeProtocol handler bytes = do
  case handlerFormat handler of
    "json" -> case decodeJSON bytes of
      Just value -> return $ Right value
      Nothing -> return $ Left "Failed to decode JSON"
    _ -> return $ Left $ "Unsupported format: " ++ handlerFormat handler

-- | Encode data to JSON
encodeJSON :: ToJSON a => a -> BSL.ByteString
encodeJSON = Data.Aeson.encode

-- | Decode data from JSON
decodeJSON :: FromJSON a => BSL.ByteString -> Maybe a
decodeJSON = Data.Aeson.decode