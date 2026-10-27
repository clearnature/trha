{-# LANGUAGE OverloadedStrings #-}

module UI.ThemeSpec (spec) where

import Test.Hspec
import UI.Theme
import Data.List (nub)
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as T

spec :: Spec
spec = do
  describe "themes" $ do
    it "ships 32 built-in themes with unique names" $ do
      length themes `shouldBe` 32
      let names = map themeName themes
      length (nub names) `shouldBe` length names
    it "resolves every name case-insensitively" $
      mapM_ (\n -> themeName (resolveTheme (T.toUpper n)) `shouldBe` n) (map themeName themes)
  describe "resolveTheme" $ do
    it "resolves the default theme by name" $ do
      themeName (resolveTheme "tokyo-night") `shouldBe` "tokyo-night"

    it "resolves the light theme by name" $ do
      themeName (resolveTheme "light") `shouldBe` "light"

    it "is case-insensitive" $ do
      themeName (resolveTheme "TOKYO-NIGHT") `shouldBe` "tokyo-night"
      themeName (resolveTheme "Light") `shouldBe` "light"

    it "falls back to the default theme for unknown names" $ do
      themeName (resolveTheme "does-not-exist") `shouldBe` "tokyo-night"

    it "falls back for an empty name" $ do
      themeName (resolveTheme "") `shouldBe` "tokyo-night"

  describe "defaultTheme" $ do
    it "is the tokyo-night palette" $ do
      themeName defaultTheme `shouldBe` "tokyo-night"

  describe "roleColor" $ do
    it "returns a colour for every documented role" $ do
      let isColour (ColorSpec fg _) = fg /= Black
      mapM_ (\r -> roleColor defaultTheme r `shouldSatisfy` isColour) roles

    it "returns a fallback for unknown roles" $ do
      roleColor defaultTheme "nope" `shouldBe` ColorSpec White []

    it "differs between themes for the same role" $ do
      roleColor defaultTheme "header" /= roleColor (resolveTheme "light") "header"

    it "uses the assistant colour for assistant messages" $ do
      roleColor defaultTheme "assistant" `shouldBe` ColorSpec BrightBlue []

  describe "themeAttrNames" $ do
    it "documents the role names the UI uses" $ do
      "header" `elem` themeAttrNames `shouldBe` True
      "assistant" `elem` themeAttrNames `shouldBe` True
      "codeBlock" `elem` themeAttrNames `shouldBe` True
      "diffAdd" `elem` themeAttrNames `shouldBe` True

  describe "palette completeness" $ do
    it "defines every documented role in both themes" $ do
      mapM_ (\th -> mapM_
              (\r -> lookup r (themeColors th) `shouldSatisfy` isJust)
              themeAttrNames)
            [defaultTheme, (resolveTheme "light")]

    it "gives the diff roles real colours (not the White fallback)" $ do
      roleColor defaultTheme "diffAdd" `shouldBe` ColorSpec BrightGreen []
      roleColor defaultTheme "diffRemove" `shouldBe` ColorSpec BrightRed []
      roleColor (resolveTheme "light") "diffAdd" `shouldBe` ColorSpec Green []
      roleColor (resolveTheme "light") "diffRemove" `shouldBe` ColorSpec Red []

  describe "truecolor" $ do
    it "detects COLORTERM=truecolor and 24bit" $ do
      supportsTrueColor [("COLORTERM", "truecolor")] `shouldBe` True
      supportsTrueColor [("COLORTERM", "24bit")] `shouldBe` True
      supportsTrueColor [("COLORTERM", "TRUECOLOR")] `shouldBe` True

    it "rejects 256-colour and missing COLORTERM" $ do
      supportsTrueColor [("COLORTERM", "256")] `shouldBe` False
      supportsTrueColor [] `shouldBe` False

    it "keeps the ANSI palette when unsupported" $ do
      themeColors (themeFor "light" False) `shouldBe` themeColors (resolveTheme "light")

    it "upgrades every documented role to RGB for both palettes" $ do
      mapM_ (\name -> mapM_
              (\r -> case roleColor (themeFor name True) r of
                       ColorSpec RGB{} _ -> pure ()
                       other -> expectationFailure
                         (T.unpack name <> "/" <> T.unpack r <> ": " <> show other))
              themeAttrNames)
            ["tokyo-night", "light"]

roles :: [Text]
roles =
  [ "header", "user", "assistant", "tool", "system", "error", "input"
  , "status", "timestamp", "border", "title", "busy", "plan"
  , "codeBlock", "codeLang"
  ]
