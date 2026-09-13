{-# LANGUAGE OverloadedStrings #-}

module Orchestration.Bridge.Types
  ( BridgeConfig(..)
  , QueryRequest(..)
  , QueryResponse(..)
  , VerifyRequest(..)
  , VerifyResponse(..)
  ) where

import Data.Text (Text)

-- | Bridge configuration
data BridgeConfig = BridgeConfig
  { bridgeHost :: Text
  , bridgePort :: Int
  } deriving (Show, Eq)

-- | Query request to Haskell core
data QueryRequest = QueryRequest
  { queryMessages :: [(Text, Text)]
  } deriving (Show, Eq)

-- | Query response from Haskell core
data QueryResponse = QueryResponse
  { responseChunks :: [Text]
  } deriving (Show, Eq)

-- | Verify request to Haskell core
data VerifyRequest = VerifyRequest
  { verifyTypeRep :: Text
  , verifyValue   :: Text
  } deriving (Show, Eq)

-- | Verify response from Haskell core
data VerifyResponse = VerifyResponse
  { verifyResult :: Bool
  , verifyError  :: Maybe Text
  } deriving (Show, Eq)