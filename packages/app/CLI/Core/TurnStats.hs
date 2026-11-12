{-# LANGUAGE OverloadedStrings #-}

-- | Per-turn token accounting line (Reasonix parity):
--
-- @
-- 本轮 508.4K tok · in 507.9K · cached 507.1K · new 770 · out 543 · reasoning 50 · ≈¥0.0131 · 低峰
-- @
--
-- Pure: numbers come from the provider's usage echo, prices from settings
-- (or @TRHA_PRICE_*@), and the peak flag from the local clock.  Kept out of
-- "UI.Brick" so the formatting is unit-tested.
module Core.TurnStats
  ( Prices(..)
  , noPrices
  , hasPrices
  , pricesForModel
  , pricesPeakForModel
  , pricesAt
  , estimateCost
  , isOffPeak
  , shortCount
  , turnSummary
  ) where

import Core.Types (Usage(..), usageContextUsed)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (Day, DayOfWeek(..), dayOfWeek, fromGregorian)
import Data.Time.Clock (UTCTime)
import Data.Time.LocalTime
  ( hoursToTimeZone, localDay, localTimeOfDay, todHour, todMin, utcToZonedTime
  , zonedTimeToLocalTime )
import Numeric (showFFloat)

-- | Prices per million tokens (CNY), mirroring the provider's billing table.
data Prices = Prices
  { priceInput  :: Double -- ^ cache-miss prompt tokens
  , priceCached :: Double -- ^ cache-hit prompt tokens
  , priceOutput :: Double -- ^ completion tokens
  } deriving (Show, Eq)

noPrices :: Prices
noPrices = Prices 0 0 0

-- | All three prices known; a partial table would produce a misleading cost.
hasPrices :: Prices -> Bool
hasPrices p = priceInput p > 0 && priceCached p > 0 && priceOutput p > 0

-- | Built-in CNY prices per 1M tokens: DeepSeek's **off-peak** card.  Unknown
-- models fall back to 'noPrices' so the line shows @≈¥—@ instead of a guess.
--
-- DeepSeek publishes two cards (09:00–12:00 and 14:00–18:00 Beijing are the
-- peak hours); 'pricesPeakForModel' carries the second one and 'pricesAt'
-- picks by the turn's clock.  Applying the peak card around the clock — or
-- the old 0.5 cached rate — overstates a cached turn by an order of magnitude.
pricesForModel :: Text -> Prices
pricesForModel model
  | "deepseek-v4-pro" `T.isPrefixOf` m = Prices 3 0.025 6
  | "deepseek" `T.isPrefixOf` m = Prices 1 0.02 4
  | otherwise = noPrices
  where m = T.toLower (T.strip model)

-- | The vendors' peak card, when they publish one.  'Nothing' means the model
-- bills a single rate all day.
pricesPeakForModel :: Text -> Maybe Prices
pricesPeakForModel model
  | "deepseek-v4-pro" `T.isPrefixOf` m = Just (Prices 9 0.3 27)
  | "deepseek" `T.isPrefixOf` m = Just (Prices 2 0.04 8)
  | otherwise = Nothing
  where m = T.toLower (T.strip model)

-- | The card that applies at @at@: the peak one inside the vendor's window,
-- the base one otherwise.
pricesAt :: UTCTime -> Prices -> Maybe Prices -> Prices
pricesAt at base mpeak
  | not (isOffPeak at), Just peak <- mpeak = peak
  | otherwise = base

-- | Estimated cost in CNY.  Without cache fields the whole prompt is billed
-- at the miss price.
estimateCost :: Prices -> Usage -> Double
estimateCost p u =
  (fromIntegral miss * priceInput p
    + fromIntegral (usageCacheHitTokens u) * priceCached p
    + fromIntegral (usageCompletionTokens u) * priceOutput p) / 1e6
  where
    cacheSeen = usageCacheHitTokens u + usageCacheMissTokens u > 0
    miss = if cacheSeen then usageCacheMissTokens u else usagePromptTokens u

-- | DeepSeek's peak window: 09:00–12:00 and 14:00–18:00 Beijing time.  The
-- vendor's clock decides, never the reader's.  Weekends are off-peak from
-- 2026-08-23; the statutory-holiday table is deliberately not encoded here —
-- a stale holiday list would silently misprice a day.
isOffPeak :: UTCTime -> Bool
isOffPeak t =
  let lt = zonedTimeToLocalTime (utcToZonedTime (hoursToTimeZone 8) t)
      mins = todHour (localTimeOfDay lt) * 60 + todMin (localTimeOfDay lt)
      peak = (mins >= 9 * 60 && mins < 12 * 60)
          || (mins >= 14 * 60 && mins < 18 * 60)
  in weekendOff (localDay lt) || not peak

-- | Saturdays and Sundays stop paying the peak card from 2026-08-23.
weekendOff :: Day -> Bool
weekendOff day =
  day >= fromGregorian 2026 8 23
    && dayOfWeek day `elem` [Saturday, Sunday]

-- | Compact token counts: @770@, @507.9K@, @1.5M@.
shortCount :: Int -> Text
shortCount n
  | n >= 1000000 = T.pack (showFFloat (Just 1) (fromIntegral n / 1e6 :: Double) "") <> "M"
  | n >= 1000    = T.pack (showFFloat (Just 1) (fromIntegral n / 1e3 :: Double) "") <> "K"
  | otherwise    = T.pack (show n)

-- | The per-turn line.  Cache fields are omitted when the provider does not
-- report them, and the cost reads @≈¥—@ until prices are configured.
--
-- @in@ is the *billable* prompt total for the turn: a tool loop issues one
-- model call per round and the scheduler sums their prompts.  That makes the
-- number legitimately larger than the context, so a multi-round turn also
-- prints @ctx@ — the latest single request — and the two are never conflated.
turnSummary :: Prices -> Usage -> Int -> UTCTime -> Text
turnSummary p u reasoning at =
  T.intercalate " · " (concat
    [ [ "本轮 " <> shortCount (usagePromptTokens u + usageCompletionTokens u) <> " tok" ]
    , [ "in " <> shortCount (usagePromptTokens u) ]
    , [ "ctx " <> shortCount (ctxUsed u) | multiRound ]
    , cacheParts
    , [ "out " <> shortCount (usageCompletionTokens u) ]
    , [ "reasoning " <> T.pack (show reasoning) | reasoning > 0 ]
    , [ costPart ]
    , [ if isOffPeak at then "低峰" else "高峰" ]
    ])
  where
    ctxUsed = usageContextUsed
    -- Only a tool loop (or a resend) can make the bill exceed one request;
    -- printing @ctx@ on every ordinary turn would just add noise.
    multiRound = usagePromptTokens u > 0
              && ctxUsed u > 0
              && ctxUsed u /= usagePromptTokens u
    cacheParts
      | usageCacheHitTokens u + usageCacheMissTokens u > 0 =
          [ "cached " <> shortCount (usageCacheHitTokens u)
          , "new " <> shortCount (usageCacheMissTokens u)
          ]
      | otherwise = []
    costPart
      | hasPrices p = "≈¥" <> T.pack (showFFloat (Just 4) (estimateCost p u) "")
      | otherwise   = "≈¥—"
