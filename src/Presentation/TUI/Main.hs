{-# LANGUAGE OverloadedStrings #-}

module Presentation.TUI.Main
  ( TUIApp(..)
  , createTUIApp
  , startTUIApp
  ) where

import Data.Text (Text)

-- | TUI application configuration
data TUIApp = TUIApp
  { tuiAppTitle :: Text
  , tuiAppTheme :: Text
  } deriving (Show, Eq)

-- | Create a new TUI application
createTUIApp :: Text -> Text -> TUIApp
createTUIApp title theme = TUIApp title theme

-- | Start the TUI application (placeholder)
startTUIApp :: TUIApp -> IO ()
startTUIApp app = do
  putStrLn $ "Starting TUI application: " ++ show (tuiAppTitle app)
  putStrLn $ "Theme: " ++ show (tuiAppTheme app)
  -- Placeholder: in real implementation, start Pi TUI
  putStrLn "TUI application started"