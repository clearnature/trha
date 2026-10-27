{-# LANGUAGE OverloadedStrings #-}

module Presentation.Desktop.Tray
  ( TrayIcon(..)
  , createTrayIcon
  , setTrayMenu
  , showTrayNotification
  ) where

import Data.Text (Text)
import qualified Data.Text as T

-- | Tray icon configuration
data TrayIcon = TrayIcon
  { trayIconPath :: Text
  , trayTooltip :: Text
  }

-- | Create a new tray icon
createTrayIcon :: Text -> Text -> IO TrayIcon
createTrayIcon iconPath tooltip = do
  return $ TrayIcon iconPath tooltip

-- | Set the tray menu
setTrayMenu :: TrayIcon -> [Text] -> IO ()
setTrayMenu tray menuItems = do
  putStrLn $ "Setting tray menu for: " ++ T.unpack (trayTooltip tray)
  mapM_ (\item -> putStrLn $ "  - " ++ T.unpack item) menuItems

-- | Show a tray notification
showTrayNotification :: TrayIcon -> Text -> Text -> IO ()
showTrayNotification tray title body = do
  putStrLn $ "Showing tray notification: " ++ T.unpack title
  putStrLn $ "Body: " ++ T.unpack body