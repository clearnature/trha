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
  , themeNames
  , themeAttrNames
    -- * Resolution
  , resolveTheme
  , roleColor
    -- * Truecolor
  , supportsTrueColor
  , themeFor
  ) where

import Data.Char (toLower)
import Data.List (isInfixOf)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T

-- | ANSI-ish terminal colours, plus exact RGB for truecolor terminals.
data TermColor
  = Black | Red | Green | Yellow | Blue | Magenta | Cyan | White
  | BrightBlack | BrightRed | BrightGreen | BrightYellow
  | BrightBlue | BrightMagenta | BrightCyan | BrightWhite
  | RGB Int Int Int
  deriving (Show, Eq, Ord)

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
  , "diffAdd", "diffRemove", "diffHunk", "diffMeta"
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
  , ("diffAdd",    ColorSpec BrightGreen [])
  , ("diffRemove", ColorSpec BrightRed [])
  , ("diffHunk",   ColorSpec BrightCyan [])
  , ("diffMeta",   ColorSpec BrightBlack [])
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
  , ("diffAdd",    ColorSpec Green [])
  , ("diffRemove", ColorSpec Red [])
  , ("diffHunk",   ColorSpec Blue [])
  , ("diffMeta",   ColorSpec BrightBlack [])
  , ("selection", ColorSpec Black [StyleReverse])
  ]

-- | All built-in themes.
themes :: [Theme]
themes =
  [ defaultTheme, lightTheme
  , gruvboxTheme, draculaTheme, nordTheme
  , solarizedDarkTheme, monokaiTheme, solarizedLightTheme
  ]
  ++
  [ mkPalette "catppuccin-mocha"     (Magenta,     Blue,       Green,       Yellow,      Red,       BrightBlack)
  , mkPalette "catppuccin-frappe"    (Magenta,     Blue,       Green,       Yellow,      Red,       BrightBlack)
  , mkPalette "catppuccin-macchiato" (Magenta,     Blue,       Green,       Yellow,      Red,       BrightBlack)
  , mkPalette "catppuccin-latte"     (Blue,        Blue,       Green,       Yellow,      Red,       BrightBlack)
  , mkPalette "one-dark"             (Blue,        Blue,       Green,       Yellow,      Red,       BrightBlack)
  , mkPalette "one-light"            (Blue,        Blue,       Green,       Yellow,      Red,       BrightBlack)
  , mkPalette "github-dark"          (Blue,        Blue,       Green,       Yellow,      Red,       BrightBlack)
  , mkPalette "github-light"         (Blue,        Blue,       Green,       Yellow,      Red,       BrightBlack)
  , mkPalette "ayu-dark"             (Yellow,      Blue,       Green,       Yellow,      Red,       BrightBlack)
  , mkPalette "ayu-light"            (Blue,        Blue,       Green,       Yellow,      Red,       BrightBlack)
  , mkPalette "rose-pine"            (Magenta,     Blue,       Green,       Yellow,      Red,       BrightBlack)
  , mkPalette "rose-pine-dawn"       (Magenta,     Blue,       Green,       Yellow,      Red,       BrightBlack)
  , mkPalette "kanagawa"             (Yellow,      Blue,       Green,       Yellow,      Red,       BrightBlack)
  , mkPalette "everforest"           (Green,       Blue,       Green,       Yellow,      Red,       BrightBlack)
  , mkPalette "tokyo-night-storm"    (Cyan,        Blue,       Green,       Yellow,      Red,       BrightBlack)
  , mkPalette "material"             (Cyan,        Blue,       Green,       Yellow,      Red,       BrightBlack)
  , mkPalette "night-owl"            (Cyan,        Blue,       Green,       Yellow,      Red,       BrightBlack)
  , mkPalette "palenight"            (Magenta,     Blue,       Green,       Yellow,      Red,       BrightBlack)
  , mkPalette "oceanic-next"         (Cyan,        Blue,       Green,       Yellow,      Red,       BrightBlack)
  , mkPalette "spacegray"            (Blue,        Blue,       Green,       Yellow,      Red,       BrightBlack)
  , mkPalette "tomorrow-night"       (Blue,        Blue,       Green,       Yellow,      Red,       BrightBlack)
  , mkPalette "zenburn"              (Yellow,      Blue,       Green,       Yellow,      Red,       BrightBlack)
  , mkPalette "monokai-pro"          (Magenta,     Cyan,       Green,       Yellow,      Red,       BrightBlack)
  , mkPalette "solarized-light-hc"   (Blue,        Blue,       Green,       Yellow,      Red,       BrightBlack)
  ]

-- | Names of the built-in themes (for @/theme@ and the picker).
themeNames :: [Text]
themeNames = map themeName themes

-- | A palette from six anchors: accent, assistant, ok, warn, error, muted.
-- Every new theme only has to choose those (the roles stay consistent).
mkPalette :: Text -> (TermColor, TermColor, TermColor, TermColor, TermColor, TermColor) -> Theme
mkPalette name (accent, assistantC, ok, warn, err, muted) = Theme name
  [ ("header",    ColorSpec accent [StyleBold])
  , ("user",      ColorSpec ok [StyleBold])
  , ("assistant", ColorSpec assistantC [])
  , ("tool",      ColorSpec accent [])
  , ("system",    ColorSpec warn [])
  , ("error",     ColorSpec err [StyleBold])
  , ("input",     ColorSpec accent [])
  , ("status",    ColorSpec muted [])
  , ("timestamp", ColorSpec muted [])
  , ("border",    ColorSpec muted [])
  , ("title",     ColorSpec accent [StyleBold])
  , ("busy",      ColorSpec warn [StyleBold])
  , ("plan",      ColorSpec accent [StyleBold])
  , ("codeBlock", ColorSpec muted [])
  , ("codeLang",  ColorSpec warn [StyleBold])
  , ("mdBold",    ColorSpec accent [StyleBold])
  , ("mdCode",    ColorSpec accent [])
  , ("diffAdd",   ColorSpec ok [])
  , ("diffRemove", ColorSpec err [])
  , ("diffHunk",  ColorSpec accent [])
  , ("diffMeta",  ColorSpec muted [])
  , ("selection", ColorSpec accent [StyleReverse])
  ]

gruvboxTheme, draculaTheme, nordTheme, solarizedDarkTheme, monokaiTheme, solarizedLightTheme :: Theme
gruvboxTheme        = mkPalette "gruvbox"         (Yellow,     Blue,         Green,       Yellow,      Red,       BrightBlack)
draculaTheme        = mkPalette "dracula"         (Magenta,    Cyan,         Green,       Yellow,      Red,       BrightBlack)
nordTheme           = mkPalette "nord"            (BrightCyan, BrightBlue,   BrightGreen, BrightYellow, BrightRed, BrightBlack)
solarizedDarkTheme  = mkPalette "solarized-dark"  (Cyan,       Blue,         Green,       Yellow,      Red,       BrightBlack)
monokaiTheme        = mkPalette "monokai"         (Yellow,     Cyan,         Green,       Yellow,      Red,       BrightBlack)
solarizedLightTheme = mkPalette "solarized-light" (Blue,       Blue,         Green,       Yellow,      Red,       BrightBlack)

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

-- | Whether the environment advertises a truecolor (24-bit) terminal.
supportsTrueColor :: [(String, String)] -> Bool
supportsTrueColor env = case lookup "COLORTERM" env of
  Just v  -> let lv = map toLower v
             in "truecolor" `isInfixOf` lv || "24bit" `isInfixOf` lv
  Nothing -> False

-- | Theme for a name, upgraded to exact RGB when the terminal can show it.
-- Roles missing from the RGB table keep their ANSI colour.
themeFor :: Text -> Bool -> Theme
themeFor name truecolor
  | truecolor = upgradeToTrueColor (resolveTheme name)
  | otherwise = resolveTheme name

upgradeToTrueColor :: Theme -> Theme
upgradeToTrueColor th = case T.toLower (themeName th) of
  "tokyo-night" -> applyTable darkTrueColor th
  "light"       -> applyTable lightTrueColor th
  _             -> th  -- ANSI themes stay as they are
  where
    applyTable table t =
      t { themeColors =
             [ (role, case lookup role table of
                        Just rgb -> cs { csFg = rgb }
                        Nothing  -> cs)
             | (role, cs) <- themeColors t ] }

-- | Tokyo Night RGB values (the dark palette).
darkTrueColor :: [(Text, TermColor)]
darkTrueColor =
  [ ("header",    RGB 125 207 255)
  , ("user",      RGB 158 206 106)
  , ("assistant", RGB 122 162 247)
  , ("tool",      RGB 187 154 247)
  , ("system",    RGB 224 175 104)
  , ("error",     RGB 247 118 142)
  , ("input",     RGB 125 207 255)
  , ("status",    RGB 86 95 137)
  , ("timestamp", RGB 86 95 137)
  , ("border",    RGB 86 95 137)
  , ("title",     RGB 187 154 247)
  , ("busy",      RGB 224 175 104)
  , ("plan",      RGB 125 207 255)
  , ("codeBlock", RGB 86 95 137)
  , ("codeLang",  RGB 224 175 104)
  , ("mdBold",    RGB 192 202 245)
  , ("mdCode",    RGB 125 207 255)
  , ("diffAdd",   RGB 158 206 106)
  , ("diffRemove",RGB 247 118 142)
  , ("diffHunk",  RGB 125 207 255)
  , ("diffMeta",  RGB 86 95 137)
  , ("selection", RGB 192 202 245)
  ]

-- | RGB values for light terminals (dark text on light backgrounds).
lightTrueColor :: [(Text, TermColor)]
lightTrueColor =
  [ ("header",    RGB 46 92 184)
  , ("user",      RGB 47 125 50)
  , ("assistant", RGB 31 95 191)
  , ("tool",      RGB 123 47 190)
  , ("system",    RGB 138 109 0)
  , ("error",     RGB 179 38 30)
  , ("input",     RGB 46 92 184)
  , ("status",    RGB 95 99 104)
  , ("timestamp", RGB 95 99 104)
  , ("border",    RGB 32 33 36)
  , ("title",     RGB 123 47 190)
  , ("busy",      RGB 138 109 0)
  , ("plan",      RGB 46 92 184)
  , ("codeBlock", RGB 95 99 104)
  , ("codeLang",  RGB 138 109 0)
  , ("mdBold",    RGB 32 33 36)
  , ("mdCode",    RGB 46 92 184)
  , ("diffAdd",   RGB 47 125 50)
  , ("diffRemove",RGB 179 38 30)
  , ("diffHunk",  RGB 46 92 184)
  , ("diffMeta",  RGB 95 99 104)
  , ("selection", RGB 32 33 36)
  ]
