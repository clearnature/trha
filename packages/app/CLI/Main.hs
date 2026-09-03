{-# LANGUAGE OverloadedStrings #-}

module Main where

import Core.Types
import Core.Client
import UI.Commands
import Bridge.Scheduler
import Config.Settings
import Data.Text (Text)
import qualified Data.Text as T

main :: IO ()
main = do
  putStrLn "gh-harness CLI"
  putStrLn "Type 'help' for commands, 'quit' to exit"
  
  -- Load configuration
  config <- loadConfig
  let cliConfig = case config of
        Just c -> c
        Nothing -> defaultCLIConfig
  
  -- Create scheduler bridge
  bridge <- createSchedulerBridge cliConfig
  
  -- Run CLI loop
  repl bridge

repl :: SchedulerBridge -> IO ()
repl bridge = do
  putStr "> "
  input <- getLine
  
  let command = parseCommand (T.pack input)
  
  case command of
    Quit -> putStrLn "Goodbye!"
    _ -> do
      result <- executeCommand command
      case result of
        Just msg -> putStrLn $ T.unpack msg
        Nothing -> return ()
      repl bridge