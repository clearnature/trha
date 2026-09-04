{-# LANGUAGE OverloadedStrings #-}

module Main where

import Core.Server
import Core.Types
import Data.Text (Text)

main :: IO ()
main = do
  putStrLn "Starting trha SDK server..."
  let server = createServer 3000 "localhost"
  startServer server