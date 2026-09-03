{-# LANGUAGE OverloadedStrings #-}

module Serializer.Serializer
  ( -- * Serializer
    Serializer(..)
  , createSerializer
  
    -- * Serialization
  , serialize
  , deserialize
  , serializeToString
  , deserializeFromString
  ) where

import Data.Aeson
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.ByteString.Lazy as BSL

-- | Serializer
data Serializer = Serializer
  { serializerFormat :: String
  }

-- | Create a new serializer
createSerializer :: String -> IO Serializer
createSerializer format = do
  return $ Serializer format

-- | Serialize data
serialize :: ToJSON a => Serializer -> a -> IO (Either String BSL.ByteString)
serialize serializer data_ = do
  case serializerFormat serializer of
    "json" -> return $ Right $ Data.Aeson.encode data_
    _ -> return $ Left $ "Unsupported format: " ++ serializerFormat serializer

-- | Deserialize data
deserialize :: FromJSON a => Serializer -> BSL.ByteString -> IO (Either String a)
deserialize serializer bytes = do
  case serializerFormat serializer of
    "json" -> case Data.Aeson.decode bytes of
      Just value -> return $ Right value
      Nothing -> return $ Left "Failed to decode JSON"
    _ -> return $ Left $ "Unsupported format: " ++ serializerFormat serializer

-- | Serialize data to string
serializeToString :: ToJSON a => Serializer -> a -> IO (Either String Text)
serializeToString serializer data_ = do
  result <- serialize serializer data_
  case result of
    Right bytes -> return $ Right $ T.pack $ show bytes
    Left err -> return $ Left err

-- | Deserialize data from string
deserializeFromString :: FromJSON a => Serializer -> Text -> IO (Either String a)
deserializeFromString serializer text = do
  let bytes = BSL.fromStrict $ T.encodeUtf8 text
  deserialize serializer bytes