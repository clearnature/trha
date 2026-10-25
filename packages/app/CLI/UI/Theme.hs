{-# LANGUAGE OverloadedStrings #-}

-- | Terminal colour tokens used by UI themes.  Kept independent of brick so
-- the theme logic stays pure and unit-testable; "UI.Brick" maps these to
-- vty attributes.
module UI.Theme
  ( -- * Colours
    TermColor(..)
    -- * Styles & roles
  , TermStyle(..)
  , ColorSpec(..)
  , Theme(..)
    -- * Palette
  , defaultTheme
  , themes
  , themeAttrNames
    -- * Resolution
  , resolveTheme
  , roleColor
  ) where

import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T

-- | ANSI-ish terminal colours.
data TermColor
  = Black | Red | Green | Yellow | Blue | Magenta | Cyan | White
  | BrightBlack | BrightRed | BrightGreen | BrightYellow
  | BrightBlue | BrightMagenta | BrightCyan | BrightWhite
  deriving (Show, Eq, Ord, Enum, Bounded)

-- | Text styles applied on top of the foreground colour.
data TermStyle = StyleBold | StyleDim | StyleReverse
  deriving (Show, Eq)

-- | Colour specification for one UI role.
data ColorSpec = ColorSpec
  { csFg    :: TermColor
  , csStyle :: [TermStyle]
  } deriving (Show, Eq)

-- | A named colour palette for the terminal UI.
data Theme = Theme
  { themeName   :: Text
  , themeColors :: [(Text, ColorSpec)]
  } deriving (Show, Eq)

-- | Role names the UI draws.
themeAttrNames :: [Text]
themeAttrNames =
  [ "header", "user", "assistant", "tool", "system", "error", "input"
  , "status", "timestamp", "border", "title", "busy", "plan"
  , "codeBlock", "codeLang", "mdBold", "mdCode"
  , "selection"
  ]

-- | The default dark palette (Tokyo Night inspired, as before).
defaultTheme :: Theme
defaultTheme = Theme "tokyo-night"
  [ ("header",    ColorSpec BrightCyan [StyleBold])
  , ("user",      ColorSpec BrightGreen [StyleBold])
  , ("assistant", ColorSpec BrightBlue [])
  , ("tool",      ColorSpec BrightMagenta [])
  , ("system",    ColorSpec Yellow [])
  , ("error",     ColorSpec BrightRed [StyleBold])
  , ("input",     ColorSpec BrightCyan [])
  , ("status",    ColorSpec BrightBlack [])
  , ("timestamp", ColorSpec BrightBlack [])
  , ("border",    ColorSpec BrightBlack [])
  , ("title",     ColorSpec Magenta [StyleBold])
  , ("busy",      ColorSpec Yellow [StyleBold])
  , ("plan",      ColorSpec BrightCyan [StyleBold])
  , ("codeBlock", ColorSpec BrightBlack [])
  , ("codeLang",  ColorSpec BrightYellow [StyleBold])
  , ("mdBold",     ColorSpec BrightWhite [StyleBold])
  , ("mdCode",     ColorSpec BrightCyan [])
  , ("selection", ColorSpec BrightWhite [StyleReverse])
  ]

-- | A light-terminal palette (dark text on light backgrounds).
lightTheme :: Theme
lightTheme = Theme "light"
  [ ("header",    ColorSpec Blue [StyleBold])
  , ("user",      ColorSpec Green [StyleBold])
  , ("assistant", ColorSpec Blue [])
  , ("tool",      ColorSpec Magenta [])
  , ("system",    ColorSpec Yellow [])
  , ("error",     ColorSpec Red [StyleBold])
  , ("input",     ColorSpec Blue [])
  , ("status",    ColorSpec BrightBlack [])
  , ("timestamp", ColorSpec BrightBlack [])
  , ("border",    ColorSpec Black [])
  , ("title",     ColorSpec Magenta [StyleBold])
  , ("busy",      ColorSpec Yellow [StyleBold])
  , ("plan",      ColorSpec Blue [StyleBold])
  , ("codeBlock", ColorSpec BrightBlack [])
  , ("codeLang",  ColorSpec Yellow [StyleBold])
  , ("mdBold",     ColorSpec Black [StyleBold])
  , ("mdCode",     ColorSpec Blue [])
  , ("selection", ColorSpec Black [StyleReverse])
  ]

-- | All built-in themes.
themes :: [Theme]
themes = [defaultTheme, lightTheme]

-- | Resolve a theme name (case-insensitive); unknown or empty names fall
-- back to 'defaultTheme'.
resolveTheme :: Text -> Theme
resolveTheme name =
  fromMaybe defaultTheme
    (lookup (T.toLower name) [(T.toLower (themeName t), t) | t <- themes])

-- | Colour for a role; unknown roles get the neutral fallback.
roleColor :: Theme -> Text -> ColorSpec
roleColor th role =
  case lookup role (themeColors th) of
    Just cs -> cs
    Nothing -> ColorSpec White []
