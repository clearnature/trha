{-# LANGUAGE OverloadedStrings #-}

module Infrastructure.WebGPU.Main
  ( -- * Main
    main
  ) where

import Infrastructure.WebGPU.Backend
import Infrastructure.WebGPU.Types
import Infrastructure.WebGPU.Device
import Infrastructure.WebGPU.Buffer
import Infrastructure.WebGPU.Shader
import Infrastructure.WebGPU.Command
import Infrastructure.WebGPU.Compute
import Infrastructure.WebGPU.Error
import Data.Text (Text)
import qualified Data.Text as T

main :: IO ()
main = do
  putStrLn "Starting WebGPU backend..."
  
  -- Create backend
  result <- createWebGPUBackend defaultWebGPUConfig
  case result of
    Right backend -> do
      putStrLn "WebGPU backend created successfully"
      
      -- Initialize backend
      initResult <- initializeBackend backend
      case initResult of
        Right () -> do
          putStrLn "WebGPU backend initialized"
          
          -- Create buffer
          bufferResult <- createBuffer (backendDevice backend) 1024 [BufferUsageStorage]
          case bufferResult of
            Right buffer -> do
              putStrLn $ "Buffer created: " ++ show (bufferSize buffer) ++ " bytes"
            Left err -> do
              putStrLn $ "Error creating buffer: " ++ T.unpack (errorToText err)
          
          -- Shutdown
          shutdownBackend backend
          putStrLn "WebGPU backend shutdown"
          
        Left err -> do
          putStrLn $ "Error initializing backend: " ++ T.unpack (errorToText err)
    
    Left err -> do
      putStrLn $ "Error creating backend: " ++ T.unpack (errorToText err)