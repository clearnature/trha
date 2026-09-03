{-# LANGUAGE OverloadedStrings #-}

module Presentation.Desktop.Main
  ( DesktopApp(..)
  , createDesktopApp
  , startDesktopApp
  ) where

import Data.Text (Text)

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

-- | Start the desktop application (placeholder)
startDesktopApp :: DesktopApp -> IO ()
startDesktopApp app = do
  putStrLn $ "Starting desktop application: " ++ show (appTitle app)
  putStrLn $ "Window size: " ++ show (appWidth app) ++ "x" ++ show (appHeight app)
  putStrLn $ "Dev mode: " ++ show (appDevMode app)
  -- Placeholder: in real implementation, start Electron
  putStrLn "Electron application started"