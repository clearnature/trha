{-# LANGUAGE OverloadedStrings #-}

module UI.ThemeSpec (spec) where

import Test.Hspec
import UI.Theme
import Data.Text (Text)
import qualified Data.Text as T

spec :: Spec
spec = do
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

roles :: [Text]
roles =
  [ "header", "user", "assistant", "tool", "system", "error", "input"
  , "status", "timestamp", "border", "title", "busy", "plan"
  , "codeBlock", "codeLang"
  ]
