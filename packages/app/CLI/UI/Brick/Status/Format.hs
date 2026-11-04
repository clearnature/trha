{-# LANGUAGE OverloadedStrings #-}

-- | 状态栏的纯格式化函数：千分位、短 K、百分比、一位小数、可用宽度、
-- 上下文占用比、轮次后缀。全部是 Text/Int/Double 之间的纯转换，无副作用，
-- 可以单测（这也是从 Draw.Status 拆出来的理由——它们不碰 Widget）。
module UI.Brick.Status.Format
  ( statusCommas, statusShortK, statusPct, statusOneDec
  , statusUsable, statusCtxPct, statusTurnsSuffix
  ) where

import Data.Text (Text)
import Numeric (showFFloat)
import qualified Data.Text as T

statusCommas :: Int -> Text
statusCommas n = T.pack (reverse (go (reverse (show n))))
  where
    go [] = []
    go xs = let (a, b) = splitAt 3 xs in a ++ (if null b then [] else ',' : go b)

-- | 紧凑记法：≥1e6 用 M，≥1e3 用 K，各保留一位小数。

statusShortK :: Int -> Text
statusShortK n
  | n >= 1000000 = T.pack (showFFloat (Just 1) (fromIntegral n / 1e6 :: Double) "") <> "M"
  | n >= 1000    = T.pack (showFFloat (Just 1) (fromIntegral n / 1e3 :: Double) "") <> "K"
  | otherwise    = T.pack (show n)

-- | @a/(a+b)@ 的百分比，两位小数（缓存命中率用）。

statusPct :: Int -> Int -> Text
statusPct a b =
  T.pack (showFFloat (Just 2) (fromIntegral a * 100 / fromIntegral (a + b) :: Double) "") <> "%"

-- | 一位小数（吞吐用）。

statusOneDec :: Double -> Text
statusOneDec v = T.pack (showFFloat (Just 1) v "")

-- | 可用上下文 = 窗口的 80%（MiMo 的记账口径：预留 20% 给回复）。

statusUsable :: Int -> Int
statusUsable size = max 1 (size * 8 `div` 10)

-- | 上下文占用百分比（分母是可用窗口，不是原始窗口）。

statusCtxPct :: Int -> Int -> Int
statusCtxPct used size =
  round (fromIntegral used / fromIntegral (statusUsable size) * 100 :: Double) :: Int

-- | 报过缓存数字的轮数后缀，让稳定的百分比可解释。

statusTurnsSuffix :: Int -> Text
statusTurnsSuffix n
  | n > 0 = " · " <> T.pack (show n) <> " 轮"
  | otherwise = ""

-- | 状态栏第 2 行的统计段：缓存 / 上下文 / 压缩 / 吞吐 / token / 成本 / 余额 / 峰谷。
--
-- 段的选择与顺序由 @metrics@ 配置决定，但**配置只决定顺序**：未列出的段仍然
-- 显示。历史坑：配置早于新键的用户只看到三段，就以为其余段坏了。
