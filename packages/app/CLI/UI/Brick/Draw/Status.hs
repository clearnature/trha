{-# LANGUAGE OverloadedStrings #-}

-- | 状态栏与状态摘要的**文本层**。
--
-- 从 @UI.Brick@（4400 行）分批拆出的第二层。这一层只把 'AppState' 映射成
-- 文本（模型标签、@/status@ 摘要、价格表），不构造 Widget、不碰 @EventM@——
-- 因此可以在没有终端的情况下单测。
--
-- 依赖方向：纯函数（UI.Render.Spans）← 本层 ← 渲染（drawStatus）← 交互。
-- 反向引用一律不允许。
module UI.Brick.Draw.Status
  ( modelLabel
  , pricesOf
  , statusLine
  -- * 状态栏文本（drawStatus 的纯数据源）
  , statusSandboxTag
  , statusClock
  , statusModelLine
  , statusGitLine
  , statusPeak
  , statusStatsLine
  -- * 统计工具
  , statusCommas
  , statusShortK
  , statusPct
  , statusOneDec
  , statusUsable
  , statusCtxPct
  , statusTurnsSuffix
  ) where

import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Numeric (showFFloat)
import System.FilePath (takeFileName)

import Core.TurnStats (Prices(..), hasPrices, isOffPeak, pricesForModel)
import Core.Types
  ( CLIConfig(..), balanceCurrency, balanceTotal, configMetrics, configPriceCached
  , configPriceInput, configPriceOutput, usageCompletionTokens, usagePromptTokens
  , usageTotalTokens )
import UI.Dialog (ssEnabled)
import UI.I18n (Lang, tr)
import UI.Render.Footer (parseMetrics)
import UI.State (AppState(..))
import UI.TimeStamp (clockWithZone)

-- | @provider/model@ 或裸模型名（没有选中 provider 时）。
modelLabel :: AppState -> Text
modelLabel st =
  maybe (appModel st) (\p -> p <> "/" <> appModel st) (appProvider st)

-- | Prices from settings (all zero ⇒ the summary shows @≈¥—@).
-- | Settings prices win; otherwise the built-in table for the model.
pricesOf :: Text -> CLIConfig -> Prices
pricesOf model cfg =
  let cfgPrices = Prices (configPriceInput cfg) (configPriceCached cfg) (configPriceOutput cfg)
  in if hasPrices cfgPrices then cfgPrices else pricesForModel model

-- | @/status@ 的纯文本摘要。
statusLine :: AppState -> Text
statusLine st = T.unlines
  [ tr lang "Status:"
  , tr lang "  Session: " <> maybe (tr lang "none") T.pack (appSessionId st)
  , tr lang "  Model: " <> modelLabel st
  , "  " <> appStatus st
  ]
  where lang = appLang st
statusSandboxTag :: AppState -> Text
statusSandboxTag st =
  "SandBox:" <> (if ssEnabled (appSandbox st) then "enabled" else "disabled")

-- | 本地时钟；没有时间源时返回空串，状态栏就不渲染这一段。
statusClock :: AppState -> Text
statusClock st = case (appNow st, appTz st) of
  (Just t, Just tz) -> clockWithZone tz t
  _ -> ""

-- | 模型名 + 推理强度。
statusModelLine :: AppState -> Text
statusModelLine st = "模型 " <> modelLabel st <> "   强度 " <> appEffort st

-- | @目录@分支 [git 状态]@。
statusGitLine :: AppState -> Text
statusGitLine st =
  let ws = fromMaybe "" (lookup "workspace" (appMetrics st))
      dirName = T.pack (takeFileName (T.unpack ws))
      branch = fromMaybe "?" (lookup "git" (appMetrics st))
  in dirName <> "@" <> branch
       <> (if T.null (appGitStat st) then "" else "  " <> appGitStat st)

-- | 峰谷时段标签（DeepSeek 的低峰折扣）。
statusPeak :: AppState -> Text
statusPeak st = case appNow st of
  Just t | isOffPeak t -> "低峰"
  _ -> "高峰"

-- | 千分位分隔（21,444 而不是 21.4K），与参考实现的脚注一致。
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
statusStatsLine :: AppState -> Text
statusStatsLine st = T.intercalate "  "
  [ s | k <- statsKeys, s <- [segFor k], not (T.null s) ]
  where
    cacheSeg = case (appCacheNow st, appCacheSum st) of
      (Just (h, m), (h0, m0)) | h + m > 0 && h0 + m0 > 0 ->
        "缓存 现在 " <> statusPct h m <> " · 累计 " <> statusPct h0 m0
          <> statusTurnsSuffix (appCacheTurns st)
      _ -> ""
    ctxSeg = case (appCtxUsed st, appCtxSize st) of
      (Just used, Just size) | size > 0 ->
        "上下文 " <> statusShortK used
          <> " (" <> T.pack (show (statusCtxPct used size)) <> "%)"
      -- 窗口未知时仍显示用了多少：完全隐藏（旧行为）会让段看起来是坏的。
      (Just used, _) -> "上下文 " <> statusShortK used
      _ -> ""
    compactSeg = case (appCtxUsed st, appCtxSize st) of
      (Just used, Just size) | size > 0 ->
        "压缩 " <> T.pack (show (max 0 (100 - statusCtxPct used size))) <> "%"
      _ -> ""
    -- 两个速率同分子：端到端（从提交算）与纯解码（从首个 token 算）。
    -- 供应商报后者，用户感觉前者，两者都有时都显示。
    tpsSeg = case (appLastTps st, appLastDecodeTps st) of
      (Just e2e, Just dec) | e2e > 0 && dec > 0 ->
        "速度 " <> statusOneDec e2e <> " t/s（生成 " <> statusOneDec dec <> "）"
      (Just e2e, _) | e2e > 0 -> "速度 " <> statusOneDec e2e <> " t/s"
      (_, Just dec) | dec > 0 -> "生成 " <> statusOneDec dec <> " t/s"
      _ -> ""
    tokensSeg = case appLastUsage st of
      Just n | n > 0 -> "本轮 " <> statusCommas n <> " tok"
      _ -> ""
    usageSeg = case appUsage st of
      Just u | usageTotalTokens u > 0 ->
        "in " <> statusShortK (usagePromptTokens u)
          <> " / out " <> statusShortK (usageCompletionTokens u)
          <> " / 合计 " <> statusShortK (usageTotalTokens u)
      _ -> ""
    prices = pricesOf (appModel st) (appEffCfg st)
    costSessionSeg = if hasPrices prices
                then "会话 ¥" <> T.pack (showFFloat (Just 4) (appCostSum st) "")
                else "会话 ¥—"
    costTurnSeg = if hasPrices prices && appLastCost st > 0
                then "本次 ¥" <> T.pack (showFFloat (Just 4) (appLastCost st) "")
                else ""
    outSeg = case appUsage st of
      Just u | usageCompletionTokens u > 0 ->
        "输出 " <> statusCommas (usageCompletionTokens u)
      _ -> ""
    cacheTokensSeg = case appCacheNow st of
      Just (hit, miss) | hit + miss > 0 ->
        "命中 " <> statusCommas hit <> " | 未命中 " <> statusCommas miss
      _ -> ""
    sessTokensSeg
      | appSessTokens st > 0 = "会话 " <> statusCommas (appSessTokens st) <> " tok"
      | otherwise = ""
    peak = statusPeak st
    balanceSeg = case appBalance st of
      Just b -> "余额 " <> balanceCurrency b
                  <> T.pack (showFFloat (Just 2) (balanceTotal b) "")
      Nothing -> "余额 —"
    -- @model@/@git@/@workspace@/@session@ 在第 1 行，这里只放状态类键。
    statusKeys :: [Text]
    statusKeys = [ "cache", "ctx", "compact", "tps", "tokens", "out"
                 , "cacheTokens", "sessTokens", "costTurn", "costSession"
                 , "usage", "balance", "cost", "peak" ]
    aliasKey "context" = "ctx"
    aliasKey k = k
    configuredKeys =
      [ aliasKey k | k <- parseMetrics (configMetrics (appEffCfg st))
                   , aliasKey k `elem` statusKeys ]
    defaultStatsKeys = [ "cache", "ctx", "compact", "tps", "tokens", "out"
                       , "cacheTokens", "sessTokens", "costTurn", "costSession"
                       , "balance", "peak" ]
    statsKeys = if null configuredKeys
                  then defaultStatsKeys
                  else configuredKeys
                       ++ [ k | k <- defaultStatsKeys, k `notElem` configuredKeys ]
    segFor k = case k of
      "cache"   -> cacheSeg
      "ctx"     -> ctxSeg
      "compact" -> compactSeg
      "tps"     -> tpsSeg
      "tokens"  -> tokensSeg
      "out"     -> outSeg
      "cacheTokens" -> cacheTokensSeg
      "sessTokens"  -> sessTokensSeg
      "costTurn"    -> costTurnSeg
      "costSession" -> costSessionSeg
      "usage"   -> usageSeg
      "balance" -> balanceSeg
      "cost"    -> costSessionSeg
      "peak"    -> peak
      _         -> ""

