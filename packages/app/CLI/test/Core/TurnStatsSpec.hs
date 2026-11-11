{-# LANGUAGE OverloadedStrings #-}

module Core.TurnStatsSpec (spec) where

import Test.Hspec
import Core.TurnStats
import Core.Types (Usage(..), mkUsage)
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime(..), secondsToDiffTime)

utc :: Integer -> Int -> Int -> Int -> Int -> Int -> UTCTime
utc y mo d h mi s =
  UTCTime (fromGregorian y mo d) (secondsToDiffTime (fromIntegral (h * 3600 + mi * 60 + s)))

spec :: Spec
spec = do
  describe "shortCount" $ do
    it "uses plain numbers under 1K" $ shortCount 770 `shouldBe` "770"
    it "uses K with one decimal" $ shortCount 507900 `shouldBe` "507.9K"
    it "uses M for millions" $ shortCount 1500000 `shouldBe` "1.5M"

  describe "isOffPeak" $ do
    it "covers 09:00–12:00 and 14:00–18:00 at UTC+8" $ do
      -- 2026-10-26 is a Monday.
      isOffPeak (utc 2026 10 26 0 59 0) `shouldBe` True    -- 08:59 Beijing
      isOffPeak (utc 2026 10 26 1 0 0)  `shouldBe` False   -- 09:00 Beijing
      isOffPeak (utc 2026 10 26 3 59 0) `shouldBe` False   -- 11:59 Beijing
      isOffPeak (utc 2026 10 26 4 0 0)  `shouldBe` True    -- 12:00 Beijing
      isOffPeak (utc 2026 10 26 5 59 0) `shouldBe` True    -- 13:59 Beijing
      isOffPeak (utc 2026 10 26 6 0 0)  `shouldBe` False   -- 14:00 Beijing
      isOffPeak (utc 2026 10 26 9 59 0) `shouldBe` False   -- 17:59 Beijing
      isOffPeak (utc 2026 10 26 10 0 0) `shouldBe` True    -- 18:00 Beijing
      isOffPeak (utc 2026 10 26 12 0 0) `shouldBe` True    -- 20:00 Beijing

    it "flattens weekends from 2026-08-23" $ do
      isOffPeak (utc 2026 10 24 2 0 0) `shouldBe` True   -- Sat 10:00 Beijing
      isOffPeak (utc 2026 10 25 2 0 0) `shouldBe` True   -- Sun 10:00 Beijing
      isOffPeak (utc 2026 8 22 2 0 0)  `shouldBe` False  -- Sat before the rule
      isOffPeak (utc 2026 8 23 2 0 0)  `shouldBe` True   -- Sun on the rule

  describe "turnSummary" $ do
    it "renders the full Reasonix line" $ do
      let u = Usage 507900 543 508443 507130 770 50 507900
          p = Prices 2 0.2 8
      turnSummary p u 50 (utc 2026 10 26 16 40 0)
        `shouldBe` "本轮 508.4K tok · in 507.9K · cached 507.1K · new 770 · out 543 · reasoning 50 · ≈¥0.1073 · 低峰"

    it "omits cache and reasoning when absent" $
      turnSummary noPrices (mkUsage 100 20 120) 0 (utc 2026 10 26 2 0 0)
        `shouldBe` "本轮 120 tok · in 100 · out 20 · ≈¥— · 高峰"

  describe "estimateCost" $ do
    it "bills a prompt without cache fields at the miss price" $
      estimateCost (Prices 2 0.2 8) (mkUsage 1000000 0 1000000)
        `shouldBe` 2.0

  describe "pricesForModel" $ do
    it "knows the DeepSeek off-peak card" $ do
      pricesForModel "deepseek-flash" `shouldBe` Prices 1 0.02 4
      pricesForModel "DeepSeek-Chat" `shouldBe` Prices 1 0.02 4
    it "knows the larger DeepSeek model" $
      pricesForModel "deepseek-v4-pro" `shouldBe` Prices 3 0.025 6
    it "falls back to no prices for unknown models" $
      pricesForModel "mystery-model" `shouldBe` noPrices

  describe "pricesPeakForModel" $ do
    it "knows the DeepSeek peak card" $ do
      pricesPeakForModel "deepseek-flash" `shouldBe` Just (Prices 2 0.04 8)
      pricesPeakForModel "deepseek-v4-pro" `shouldBe` Just (Prices 9 0.3 27)
    it "has no peak card for unknown models" $
      pricesPeakForModel "mystery-model" `shouldBe` Nothing

  describe "pricesAt" $ do
    it "picks the peak card inside the window" $
      pricesAt (utc 2026 10 26 2 0 0) (Prices 1 0.02 4) (Just (Prices 2 0.04 8))
        `shouldBe` Prices 2 0.04 8
    it "keeps the base card off-peak" $
      pricesAt (utc 2026 10 26 12 0 0) (Prices 1 0.02 4) (Just (Prices 2 0.04 8))
        `shouldBe` Prices 1 0.02 4
    it "keeps the base card when the vendor has no peak price" $
      pricesAt (utc 2026 10 26 2 0 0) (Prices 1 0.02 4) Nothing
        `shouldBe` Prices 1 0.02 4
