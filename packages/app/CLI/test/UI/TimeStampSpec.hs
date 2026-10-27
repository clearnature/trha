{-# LANGUAGE OverloadedStrings #-}

module UI.TimeStampSpec (spec) where

import Test.Hspec
import UI.TimeStamp
import Data.Time
  ( TimeZone(..), UTCTime(..), fromGregorian, hoursToTimeZone, secondsToDiffTime )

-- 2026-10-26T23:31:12Z
utc :: UTCTime
utc = UTCTime (fromGregorian 2026 10 26) (secondsToDiffTime (23 * 3600 + 31 * 60 + 12))

-- UTC+8 with the glibc abbreviation.
cst :: TimeZone
cst = TimeZone 480 False "CST"

spec :: Spec
spec = do
  describe "clockWithZone" $ do
    it "shows local time with the zone abbreviation" $
      clockWithZone cst utc `shouldBe` "07:31:12 CST"
    it "falls back to a UTC offset when the zone has no name" $
      clockWithZone (hoursToTimeZone 0) utc `shouldBe` "23:31:12 UTC+00:00"

  describe "utcClock" $ do
    it "labels UTC explicitly" $
      utcClock utc `shouldBe` "23:31:12 UTC"
