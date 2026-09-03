{-# LANGUAGE OverloadedStrings #-}

module Protocol.Handler
  ( -- * Protocol Handler
    ProtocolHandler(..)
  , createProtocolHandler
  
    -- * Protocol Operations
  , serialize
  , deserialize
  , encode
  , decode
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
serialize :: ToJSON a => ProtocolHandler -> a -> IO (Either String BSL.ByteString)
serialize handler data_ = do
  case handlerFormat handler of
    "json" -> return $ Right $ encode data_
    _ -> return $ Left $ "Unsupported format: " ++ handlerFormat handler

-- | Deserialize data
deserialize :: FromJSON a => ProtocolHandler -> BSL.ByteString -> IO (Either String a)
deserialize handler bytes = do
  case handlerFormat handler of
    "json" -> case decode bytes of
      Just value -> return $ Right value
      Nothing -> return $ Left "Failed to decode JSON"
    _ -> return $ Left $ "Unsupported format: " ++ handlerFormat handler

-- | Encode data to JSON
encode :: ToJSON a => a -> BSL.ByteString
encode = Data.Aeson.encode

-- | Decode data from JSON
decode :: FromJSON a => BSL.ByteString -> Maybe a
decode = Data.Aeson.decode