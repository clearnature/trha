{-# LANGUAGE OverloadedStrings #-}

module Presentation.Desktop.Menu
  ( MenuItem(..)
  , Menu(..)
  , createMenu
  , addMenuItem
  , showMenu
  ) where

import Data.Text (Text)
import qualified Data.Text as T

-- | Menu item
data MenuItem = MenuItem
  { menuItemLabel :: Text
  , menuItemAction :: IO ()
  , menuItemEnabled :: Bool
  } deriving (Show)

-- | Menu
data Menu = Menu
  { menuItems :: [MenuItem]
  } deriving (Show)

-- | Create a new menu
createMenu :: [MenuItem] -> Menu
createMenu items = Menu items

-- | Add a menu item
addMenuItem :: Menu -> MenuItem -> Menu
addMenuItem menu item = menu { menuItems = menuItems menu ++ [item] }

-- | Show the menu
showMenu :: Menu -> IO ()
showMenu menu = do
  putStrLn "Showing menu:"
  mapM_ (\item -> putStrLn $ "  - " ++ T.unpack (menuItemLabel item)) (menuItems menu)