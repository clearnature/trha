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
  , estimateCost
  , isOffPeak
  , shortCount
  , turnSummary
  ) where

import Core.Types (Usage(..))
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (UTCTime)
import Data.Time.LocalTime
  ( hoursToTimeZone, localTimeOfDay, todHour, todMin, utcToZonedTime, zonedTimeToLocalTime )
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

-- | Built-in CNY prices per 1M tokens (DeepSeek's public list).  Unknown
-- models fall back to 'noPrices' so the line shows @≈¥—@ instead of a guess.
pricesForModel :: Text -> Prices
pricesForModel model
  | "deepseek" `T.isPrefixOf` m = Prices 2 0.5 8
  | otherwise = noPrices
  where m = T.toLower (T.strip model)

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

-- | Provider off-peak window: 00:30–08:30 at UTC+8.
isOffPeak :: UTCTime -> Bool
isOffPeak t =
  let lt = zonedTimeToLocalTime (utcToZonedTime (hoursToTimeZone 8) t)
      mins = todHour (localTimeOfDay lt) * 60 + todMin (localTimeOfDay lt)
  in mins >= 30 && mins < 8 * 60 + 30

-- | Compact token counts: @770@, @507.9K@, @1.5M@.
shortCount :: Int -> Text
shortCount n
  | n >= 1000000 = T.pack (showFFloat (Just 1) (fromIntegral n / 1e6 :: Double) "") <> "M"
  | n >= 1000    = T.pack (showFFloat (Just 1) (fromIntegral n / 1e3 :: Double) "") <> "K"
  | otherwise    = T.pack (show n)

-- | The per-turn line.  Cache fields are omitted when the provider does not
-- report them, and the cost reads @≈¥—@ until prices are configured.
turnSummary :: Prices -> Usage -> Int -> UTCTime -> Text
turnSummary p u reasoning at =
  T.intercalate " · " (concat
    [ [ "本轮 " <> shortCount (usagePromptTokens u + usageCompletionTokens u) <> " tok" ]
    , [ "in " <> shortCount (usagePromptTokens u) ]
    , cacheParts
    , [ "out " <> shortCount (usageCompletionTokens u) ]
    , [ "reasoning " <> T.pack (show reasoning) | reasoning > 0 ]
    , [ costPart ]
    , [ if isOffPeak at then "低峰" else "高峰" ]
    ])
  where
    cacheParts
      | usageCacheHitTokens u + usageCacheMissTokens u > 0 =
          [ "cached " <> shortCount (usageCacheHitTokens u)
          , "new " <> shortCount (usageCacheMissTokens u)
          ]
      | otherwise = []
    costPart
      | hasPrices p = "≈¥" <> T.pack (showFFloat (Just 4) (estimateCost p u) "")
      | otherwise   = "≈¥—"
