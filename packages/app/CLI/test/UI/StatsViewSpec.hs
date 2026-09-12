{-# LANGUAGE OverloadedStrings #-}

module UI.StatsViewSpec (spec) where

import Test.Hspec
import UI.StatsView

spec :: Spec
spec = do
  describe "buildStatsBlocks" $ do
    it "returns Session / Summary / Performance sections in order" $ do
      map sbTitleKey (buildStatsBlocks "s1" 5 (2, 1, 1, 1) (Just 88) 200)
        `shouldBe` ["Session", "Summary", "Performance"]
    it "fills the session rows from the counters" $ do
      let rows = sbRows (head (buildStatsBlocks "abc" 5 (2, 1, 1, 1) Nothing 200))
      rows `shouldBe` [ ("Session ID", "abc")
                      , ("Messages", "5")
                      , ("User", "2")
                      , ("Assistant", "1")
                      , ("Tools", "1")
                      , ("System", "1")
                      ]
    it "shows a dash for missing usage" $ do
      let rows = concatMap sbRows (buildStatsBlocks "s" 0 (0, 0, 0, 0) Nothing 0)
      rows `shouldContain` [("Last reply tokens", "—")]
    it "shows the usage number when present" $ do
      let rows = concatMap sbRows (buildStatsBlocks "s" 0 (0, 0, 0, 0) (Just 42) 0)
      rows `shouldContain` [("Last reply tokens", "42")]
