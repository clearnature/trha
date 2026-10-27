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
  describe "buildPalette" $ do
    let skills =
          [ PickerItem "/skill:zeta" "zeta" "skill"
          , PickerItem "/skill:alpha" "alpha" "skill" ]
        grouped =
          [ ("session", "会话 session", [ PickerItem "/new" "/new" "new session" ])
          , ("help", "帮助与退出 help", [ PickerItem "/help" "/help" "help" ])
          ]
    it "puts the recent slices first, then each group, then skills" $
      map piId (buildPalette
                  [ PickerItem "/skill:zeta" "zeta" "skill" ]
                  [ PickerItem "/new" "/new" "new session" ]
                  grouped skills)
        `shouldBe` [ "#recent", "/skill:zeta", "/new"
                   , "#session", "/new"
                   , "#help", "/help"
                   , "#skills", "/skill:alpha", "/skill:zeta" ]
    it "drops empty groups" $
      map piId (buildPalette [] []
                  [ ("session", "session", [])
                  , ("help", "help", [ PickerItem "/help" "/help" "help" ]) ]
                  [])
        `shouldBe` ["#recent", "#help", "/help", "#skills"]
    it "marks section headers as non-selectable" $
      all isSection (filter isSection (buildPalette [] [] grouped skills))
        `shouldBe` True

  describe "selection helpers" $ do
    let withSections =
          [ sectionItem "a" "a"
          , PickerItem "/one" "/one" ""
          , PickerItem "/two" "/two" ""
          , sectionItem "b" "b"
          , PickerItem "/three" "/three" "" ]
    it "firstSelectable skips the leading heading" $
      firstSelectable withSections `shouldBe` 1
    it "firstSelectable is 0 for an empty list" $
      firstSelectable [] `shouldBe` 0
    it "moveSelectionSkipping never lands on a heading" $ do
      moveSelectionSkipping 1 1 withSections `shouldBe` 2
      moveSelectionSkipping 1 2 withSections `shouldBe` 4
      moveSelectionSkipping (-1) 4 withSections `shouldBe` 2
    it "moveSelectionSkipping clamps at the ends" $ do
      moveSelectionSkipping 1 4 withSections `shouldBe` 4
      moveSelectionSkipping (-1) 1 withSections `shouldBe` 1
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
