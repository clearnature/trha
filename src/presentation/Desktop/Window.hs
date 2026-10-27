{-# LANGUAGE OverloadedStrings #-}

module Presentation.Desktop.Window
  ( WindowConfig(..)
  , createWindow
  , showWindow
  , hideWindow
  , closeWindow
  ) where

import Data.Text (Text)
import qualified Data.Text as T

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

-- | Create a new window
createWindow :: WindowConfig -> IO ()
createWindow config = do
  putStrLn $ "Creating window: " ++ T.unpack (windowTitle config)
  putStrLn $ "Size: " ++ show (windowWidth config) ++ "x" ++ show (windowHeight config)

-- | Show the window
showWindow :: IO ()
showWindow = putStrLn "Showing window"

-- | Hide the window
hideWindow :: IO ()
hideWindow = putStrLn "Hiding window"

-- | Close the window
closeWindow :: IO ()
closeWindow = putStrLn "Closing window"