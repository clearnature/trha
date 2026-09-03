{-# LANGUAGE OverloadedStrings #-}

module Presentation.Desktop.Tray
  ( TrayIcon(..)
  , createTrayIcon
  , setTrayMenu
  , showTrayNotification
  ) where

import Data.Text (Text)

-- | Tray icon configuration
data TrayIcon = TrayIcon
  { trayIconPath :: Text
  , trayTooltip :: Text
  }

-- | Create a new tray icon
createTrayIcon :: Text -> Text -> IO TrayIcon
createTrayIcon iconPath tooltip = do
  return $ TrayIcon iconPath tooltip

-- | Set the tray menu (placeholder)
setTrayMenu :: TrayIcon -> [Text] -> IO ()
setTrayMenu tray menuItems = do
  putStrLn $ "Setting tray menu for: " ++ show (trayTooltip tray)
  mapM_ (\item -> putStrLn $ "  - " ++ show item) menuItems

-- | Show a tray notification (placeholder)
showTrayNotification :: TrayIcon -> Text -> Text -> IO ()
showTrayNotification tray title body = do
  putStrLn $ "Showing tray notification: " ++ show title
  putStrLn $ "Body: " ++ show body