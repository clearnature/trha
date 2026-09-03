{-# LANGUAGE OverloadedStrings #-}

module Presentation.Desktop.Window
  ( WindowConfig(..)
  , createWindow
  , showWindow
  , hideWindow
  , closeWindow
  ) where

import Data.Text (Text)

-- | Window configuration
data WindowConfig = WindowConfig
  { windowTitle   :: Text
  , windowWidth   :: Int
  , windowHeight  :: Int
  , windowX       :: Maybe Int
  , windowY       :: Maybe Int
  , windowResizable :: Bool
  , windowFullscreen :: Bool
  } deriving (Show, Eq)

-- | Create a new window (placeholder)
createWindow :: WindowConfig -> IO ()
createWindow config = do
  putStrLn $ "Creating window: " ++ show (windowTitle config)
  putStrLn $ "Size: " ++ show (windowWidth config) ++ "x" ++ show (windowHeight config)

-- | Show the window (placeholder)
showWindow :: IO ()
showWindow = putStrLn "Showing window"

-- | Hide the window (placeholder)
hideWindow :: IO ()
hideWindow = putStrLn "Hiding window"

-- | Close the window (placeholder)
closeWindow :: IO ()
closeWindow = putStrLn "Closing window"