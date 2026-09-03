{-# LANGUAGE OverloadedStrings #-}

module Infrastructure.CPU.Main
  ( -- * Main
    main
  ) where

import Infrastructure.CPU.Backend
import Infrastructure.CPU.Types
import Infrastructure.CPU.Thread
import Infrastructure.CPU.SIMD
import Infrastructure.CPU.BLAS
import Infrastructure.CPU.Quant
import Infrastructure.CPU.Ops
import Infrastructure.CPU.Error
import Data.Text (Text)
import qualified Data.Text as T

main :: IO ()
main = do
  putStrLn "Starting CPU backend..."
  
  -- Create backend
  result <- createCPUBackend defaultCPUConfig
  case result of
    Right backend -> do
      putStrLn "CPU backend created successfully"
      putStrLn $ "Architecture: " ++ show (cpuBackendArch backend)
      putStrLn $ "SIMD type: " ++ show (detectSIMDType (cpuBackendFeatures backend))
      
      -- Initialize backend
      initResult <- initializeBackend backend
      case initResult of
        Right () -> do
          putStrLn "CPU backend initialized"
          
          -- Create thread pool
          poolResult <- createThreadPool (configThreads (cpuBackendConfig backend))
          case poolResult of
            Right pool -> do
              putStrLn $ "Thread pool created with " ++ show (configThreads (cpuBackendConfig backend)) ++ " threads"
              
              -- Destroy thread pool
              destroyThreadPool pool
              putStrLn "Thread pool destroyed"
            
            Left err -> do
              putStrLn $ "Error creating thread pool: " ++ T.unpack (errorToText err)
          
          -- Shutdown
          shutdownBackend backend
          putStrLn "CPU backend shutdown"
        
        Left err -> do
          putStrLn $ "Error initializing backend: " ++ T.unpack (errorToText err)
    
    Left err -> do
      putStrLn $ "Error creating backend: " ++ T.unpack (errorToText err)