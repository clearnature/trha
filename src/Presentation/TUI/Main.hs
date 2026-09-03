{-# LANGUAGE OverloadedStrings #-}

module Presentation.TUI.Main
  ( TUIApp(..)
  , createTUIApp
  , startTUIApp
  ) where

import Data.Text (Text)
import qualified Data.Text as T

-- | TUI application configuration
data TUIApp = TUIApp
  { tuiAppTitle :: Text
  , tuiAppTheme :: Text
  } deriving (Show, Eq)

-- | Create a new TUI application
createTUIApp :: Text -> Text -> TUIApp
createTUIApp title theme = TUIApp title theme

-- | Start the TUI application
startTUIApp :: TUIApp -> IO ()
startTUIApp app = do
  putStrLn $ "Starting TUI application: " ++ T.unpack (tuiAppTitle app)
  putStrLn $ "Theme: " ++ T.unpack (tuiAppTheme app)
  
  -- Initialize TUI
  putStrLn "TUI application started"
  putStrLn "Press 'q' to quit"
  
  -- Main loop
  loop
  where
    loop = do
      putStrLn "> "
      input <- getLine
      if input == "q"
        then putStrLn "Goodbye!"
        else do
          putStrLn $ "You typed: " ++ input
          loop