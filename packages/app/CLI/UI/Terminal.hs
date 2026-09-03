{-# LANGUAGE OverloadedStrings #-}

module UI.Terminal
  ( -- * Terminal UI
    printColored
  , printBold
  , printUnderline
  , clearTerminalScreen
  , moveCursor
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Console.ANSI

-- | Print colored text
printColored :: Color -> Text -> IO ()
printColored color text = do
  setSGR [SetColor Foreground Vivid color]
  TIO.putStr text
  setSGR [Reset]

-- | Print bold text
printBold :: Text -> IO ()
printBold text = do
  setSGR [SetConsoleIntensity BoldIntensity]
  TIO.putStr text
  setSGR [Reset]

-- | Print underlined text
printUnderline :: Text -> IO ()
printUnderline text = do
  setSGR [SetUnderlining SingleUnderline]
  TIO.putStr text
  setSGR [Reset]

-- | Clear the screen
clearTerminalScreen :: IO ()
clearTerminalScreen = do
  clearScreen
  setCursorPosition 0 0

-- | Move cursor to position
moveCursor :: Int -> Int -> IO ()
moveCursor = setCursorPosition