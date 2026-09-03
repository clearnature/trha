{-# LANGUAGE OverloadedStrings #-}

module Main where

import HTTP.Client
import gRPC.Client
import STM.Manager
import FFI.Bridge
import Error.Handler
import Memory.Manager
import Protocol.Handler
import Serializer.Serializer
import Data.Text (Text)
import qualified Data.Text as T

main :: IO ()
main = do
  putStrLn "Haskell-Go Bridge"
  
  -- Create HTTP client
  httpClient <- createHTTPClient "http://localhost:8080"
  
  -- Create gRPC client
  grpcClient <- createGRPCClient "localhost" 9090
  
  -- Create STM manager
  stmManager <- createSTMManager
  
  -- Create error handler
  errorHandler <- createErrorHandler "main"
  
  -- Create memory manager
  memoryManager <- createMemoryManager "main"
  
  -- Create protocol handler
  protocolHandler <- createProtocolHandler "json"
  
  -- Create serializer
  serializer <- createSerializer "json"
  
  -- Test HTTP client
  putStrLn "Testing HTTP client..."
  result <- httpGet httpClient "/health"
  case result of
    Right response -> putStrLn $ "HTTP response: " ++ show response
    Left err -> putStrLn $ "HTTP error: " ++ err
  
  -- Test gRPC client
  putStrLn "Testing gRPC client..."
  grpcResult <- getData grpcClient "test-key"
  case grpcResult of
    Right value -> putStrLn $ "gRPC response: " ++ T.unpack value
    Left err -> putStrLn $ "gRPC error: " ++ err
  
  -- Test memory manager
  putStrLn "Testing memory manager..."
  memResult <- allocateMemory memoryManager "test-block" 1024
  case memResult of
    Right block -> putStrLn $ "Allocated memory block: " ++ blockID block
    Left err -> putStrLn $ "Memory error: " ++ err
  
  putStrLn "Done"