{-# LANGUAGE OverloadedStrings #-}

module gRPC.Client
  ( -- * gRPC Client
    GRPCClient(..)
  , createGRPCClient
  
    -- * gRPC Methods
  , getData
  , setData
  , streamData
  ) where

import Data.Text (Text)
import qualified Data.Text as T

-- | gRPC client
data GRPCClient = GRPCClient
  { grpcClientHost :: String
  , grpcClientPort :: Int
  }

-- | Create a new gRPC client
createGRPCClient :: String -> Int -> IO GRPCClient
createGRPCClient host port = do
  return $ GRPCClient host port

-- | Get data from Go service
getData :: GRPCClient -> String -> IO (Either String Text)
getData client key = do
  -- Placeholder: implement gRPC call
  return $ Right "data from Go"

-- | Set data to Go service
setData :: GRPCClient -> String -> Text -> IO (Either String Bool)
setData client key value = do
  -- Placeholder: implement gRPC call
  return $ Right True

-- | Stream data from Go service
streamData :: GRPCClient -> String -> (Text -> IO ()) -> IO (Either String ())
streamData client key callback = do
  -- Placeholder: implement gRPC streaming
  callback "stream data 1"
  callback "stream data 2"
  callback "stream data 3"
  return $ Right ()