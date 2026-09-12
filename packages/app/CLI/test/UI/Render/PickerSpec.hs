{-# LANGUAGE OverloadedStrings #-}

module UI.Render.PickerSpec (spec) where

import Test.Hspec
import UI.Render.Picker
import qualified Data.Text as T

items :: [PickerItem]
items =
  [ PickerItem "/help" "/help" "Show this help"
  , PickerItem "/model" "/model <name>" "Show or set the model"
  , PickerItem "/models" "/models" "List available models"
  , PickerItem "/new" "/new" "Create a new session"
  , PickerItem "/sessions" "/sessions" "List all sessions"
  , PickerItem "/clear" "/clear" "Clear message history"
  , PickerItem "/quit" "/quit" "Exit"
  ]

spec :: Spec
spec = do
  describe "filterItems" $ do
    it "returns everything for an empty query" $ do
      filterItems "" items `shouldBe` items

    it "returns everything for a bare slash" $ do
      map piId (filterItems "/" items)
        `shouldBe` map piId items

    it "matches by substring on command and description" $ do
      map piId (filterItems "/mo" items)
        `shouldBe` ["/model", "/models"]

    it "matches inside the description too" $ do
      map piId (filterItems "session" items)
        `shouldSatisfy` (== ["/new", "/sessions"])

    it "is case-insensitive" $ do
      map piId (filterItems "/MODEL" items) `shouldBe` ["/model", "/models"]

    it "returns nothing for an unmatched query" $ do
      filterItems "/zzz" items `shouldBe` []

    it "keeps the original item order" $ do
      map piId (filterItems "/" (reverse items))
        `shouldBe` map piId (reverse items)

  describe "moveSelection" $ do
    it "clamps at the top" $ do
      moveSelection (-5) 0 4 `shouldBe` 0

    it "moves down within bounds" $ do
      moveSelection 1 0 4 `shouldBe` 1

    it "clamps at the bottom" $ do
      moveSelection 3 2 4 `shouldBe` 3

    it "handles an empty list" $ do
      moveSelection 1 0 0 `shouldBe` 0

  describe "windowRange" $ do
    it "shows all items when they fit" $ do
      windowRange 4 0 8 `shouldBe` (0, 3)

    it "keeps the selection visible when scrolled down" $ do
      windowRange 20 15 8 `shouldBe` (12, 19)

    it "clamps the window at the end" $ do
      windowRange 20 19 8 `shouldBe` (12, 19)

    it "handles an empty list" $ do
      windowRange 0 0 8 `shouldBe` (0, -1)

    it "handles a zero-height viewport" $ do
      windowRange 5 2 0 `shouldBe` (2, 1)

  describe "queryAppend / queryDelete" $ do
    it "appends a printable character" $ do
      queryAppend "/mo" 'd' `shouldBe` "/mod"

    it "deletes the last character" $ do
      queryDelete "/mod" `shouldBe` "/mo"

    it "deleting an empty query keeps it empty" $ do
      queryDelete "" `shouldBe` ""

    it "deletes a full-width character as one unit" $ do
      queryDelete "/模型" `shouldBe` "/模"
