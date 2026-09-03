{-# LANGUAGE OverloadedStrings #-}

module Orchestration.Bridge.HTTP
  ( HaskellBridge(..)
  , createHaskellBridge
  , queryModel
  , verifyType
  ) where

import Orchestration.Bridge.Types
import Infrastructure.Network.HTTP
import Data.Text (Text)
import qualified Data.Text as T

-- | HTTP bridge to Haskell core
data HaskellBridge = HaskellBridge
  { bridgeHTTP :: HTTPClient
  }

-- | Create a new Haskell bridge
createHaskellBridge :: BridgeConfig -> IO HaskellBridge
createHaskellBridge config = do
  let url = "http://" <> bridgeHost config <> ":" <> T.pack (show (bridgePort config))
  http <- createHTTPClient url
  return $ HaskellBridge http

-- | Query the Haskell core model
queryModel :: HaskellBridge -> QueryRequest -> IO (Either Text QueryResponse)
queryModel bridge request = do
  let messages = queryMessages request
  let body = T.pack $ show messages
  result <- post (bridgeHTTP bridge) "/api/query" body
  case result of
    Right response -> return $ Right $ QueryResponse [response]
    Left err -> return $ Left err

-- | Verify a type in Haskell core
verifyType :: HaskellBridge -> VerifyRequest -> IO (Either Text VerifyResponse)
verifyType bridge request = do
  let body = T.pack $ show (verifyTypeRep request, verifyValue request)
  result <- post (bridgeHTTP bridge) "/api/verify" body
  case result of
    Right response -> return $ Right $ VerifyResponse True Nothing
    Left err -> return $ Left err