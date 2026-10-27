{-# LANGUAGE OverloadedStrings #-}

module Main where

import Core.Warp
import Core.Network
import Core.Socket
import Core.ZIO
import Core.HTTP1
import Core.HTTP2
import Core.HTTP3
import Core.Protocol
import Bridge.Go
import Bridge.FFI
import Bridge.Memory
import Bridge.Channel
import App.HTTP
import App.GRPC
import App.WebSocket
import App.REST
import Data.Text (Text)
import qualified Data.Text as T

main :: IO ()
main = do
  putStrLn "Haskell Network Library"
  
  -- Create HTTP application
  let httpApp = createHTTPApp 8080 "0.0.0.0"
  
  -- Run HTTP application
  putStrLn "Starting HTTP server..."
  runHTTPApp httpApp