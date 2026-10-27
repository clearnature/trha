{-# LANGUAGE OverloadedStrings #-}

module UI.ModelPrefsSpec (spec) where

import Core.Types (ModelInfo(..))
import qualified Data.Text as T
import Test.Hspec
import UI.ModelPrefs

model :: String -> ModelInfo
model n = ModelInfo (T.pack n) "" 1000

spec :: Spec
spec = do
  describe "toggleFavorite" $ do
    it "pins and unpins" $ do
      let p = toggleFavorite "a" emptyModelPrefs
      mpFavorites p `shouldBe` ["a"]
      mpFavorites (toggleFavorite "a" p) `shouldBe` []
    it "keeps newest first without duplicates" $
      mpFavorites (toggleFavorite "a" (toggleFavorite "b" emptyModelPrefs))
        `shouldBe` ["a", "b"]

  describe "recordRecent" $ do
    it "moves a selection to the front" $
      mpRecent (recordRecent "a" (recordRecent "b" emptyModelPrefs))
        `shouldBe` ["a", "b"]
    it "caps the recent list" $ do
      let p = foldr recordRecent emptyModelPrefs
                [ T.pack ("m" ++ show n) | n <- [1 .. maxRecentModels + 3 :: Int] ]
      length (mpRecent p) `shouldBe` maxRecentModels

  describe "orderedModels" $ do
    it "puts favourites first, then recents, then the provider order" $ do
      let ms = [model "a", model "b", model "c", model "d"]
          p = recordRecent "b" (toggleFavorite "c" emptyModelPrefs)
      map modelName (orderedModels p ms) `shouldBe` ["c", "b", "a", "d"]
    it "does not duplicate a favourite that is also recent" $ do
      let ms = [model "a", model "b"]
          p = recordRecent "a" (toggleFavorite "a" emptyModelPrefs)
      map modelName (orderedModels p ms) `shouldBe` ["a", "b"]
