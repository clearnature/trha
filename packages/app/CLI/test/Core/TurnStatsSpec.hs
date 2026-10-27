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
    it "covers 00:30–08:30 at UTC+8" $ do
      isOffPeak (utc 2026 10 26 16 0 0) `shouldBe` False   -- 00:00 Beijing
      isOffPeak (utc 2026 10 26 16 30 0) `shouldBe` True   -- 00:30 Beijing
      isOffPeak (utc 2026 10 26 0 29 0) `shouldBe` True    -- 08:29 Beijing
      isOffPeak (utc 2026 10 26 0 30 0) `shouldBe` False   -- 08:30 Beijing

  describe "turnSummary" $ do
    it "renders the full Reasonix line" $ do
      let u = Usage 507900 543 508443 507130 770 50
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
    it "knows the DeepSeek list price" $ do
      pricesForModel "deepseek-flash" `shouldBe` Prices 2 0.5 8
      pricesForModel "DeepSeek-Chat" `shouldBe` Prices 2 0.5 8
    it "falls back to no prices for unknown models" $
      pricesForModel "mystery-model" `shouldBe` noPrices
