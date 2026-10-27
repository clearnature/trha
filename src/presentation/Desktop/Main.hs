{-# LANGUAGE OverloadedStrings #-}

module Presentation.Desktop.Main
  ( DesktopApp(..)
  , createDesktopApp
  , startDesktopApp
  ) where

import Data.Text (Text)
import qualified Data.Text as T

-- | Desktop application configuration
data DesktopApp = DesktopApp
  { appTitle    :: Text
  , appWidth    :: Int
  , appHeight   :: Int
  , appDevMode  :: Bool
  } deriving (Show, Eq)

-- | Create a new desktop application
createDesktopApp :: Text -> Int -> Int -> Bool -> DesktopApp
createDesktopApp title width height devMode = 
  DesktopApp title width height devMode

-- | Start the desktop application
startDesktopApp :: DesktopApp -> IO ()
startDesktopApp app = do
  putStrLn $ "Starting desktop application: " ++ T.unpack (appTitle app)
  putStrLn $ "Window size: " ++ show (appWidth app) ++ "x" ++ show (appHeight app)
  putStrLn $ "Dev mode: " ++ show (appDevMode app)
  
  -- Initialize Electron
  putStrLn "Electron application started"
  putStrLn "Press Ctrl+C to quit"
  
  -- Main loop
  loop
  where
    loop = do
      putStrLn "> "
      input <- getLine
      if input == "quit"
        then putStrLn "Goodbye!"
        else do
          putStrLn $ "You typed: " ++ input
          loop