{-# LANGUAGE OverloadedStrings #-}

module UI.FrecencySpec (spec) where

import Data.Text (Text)
import Test.Hspec
import UI.Frecency
import UI.Render.Picker (PickerItem(..))

item :: Text -> PickerItem
item i = PickerItem i i ""

spec :: Spec
spec = do
  describe "recordUse / scoreOf" $ do
    it "counts repeated uses" $ do
      let fr = recordUse "/help" (recordUse "/help" emptyFrecency)
      scoreOf "/help" fr `shouldBe` 2
      scoreOf "/models" fr `shouldBe` 0

  describe "rankItems" $ do
    it "keeps registry order when nothing has been used" $ do
      let items = [item "/help", item "/model", item "/models"]
      map piId (rankItems emptyFrecency items) `shouldBe` ["/help", "/model", "/models"]

    it "puts the most used item first, keeping ties stable" $ do
      let items = [item "/help", item "/model", item "/models", item "/skill:review"]
          fr = recordUse "/models" (recordUse "/models" (recordUse "/skill:review" emptyFrecency))
      map piId (rankItems fr items)
        `shouldBe` ["/models", "/skill:review", "/help", "/model"]

    it "does not reorder items with equal zero scores" $ do
      let items = [item "a", item "b", item "c"]
      map piId (rankItems emptyFrecency items) `shouldBe` ["a", "b", "c"]
