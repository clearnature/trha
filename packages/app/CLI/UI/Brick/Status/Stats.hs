{-# LANGUAGE OverloadedStrings #-}

-- | 状态栏第二行的统计段：缓存命中、上下文占用、压缩比、生成速度、
-- token 用量、费用、峰谷标签。整块从 Draw.Status 拆出——它有 14 个
-- where 绑定，是 Status 里最大的单函数。
module UI.Brick.Status.Stats
  ( statusStatsLine, statusPeak
  ) where

import Core.Types
import Data.Text (Text)
import qualified Data.Text as T

import UI.Brick.Status.Format
  ( statusCommas, statusCtxPct, statusOneDec, statusPct, statusShortK
  , statusTurnsSuffix )
import UI.Brick.Status.Shared (hasPricesFor)
import Core.TurnStats (isOffPeak)
import Numeric (showFFloat)
import UI.Render.Footer (parseMetrics)
import UI.State

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
    pricesKnown = hasPricesFor (appModel st) (appEffCfg st)
    costSessionSeg = if pricesKnown
                then "会话 ¥" <> T.pack (showFFloat (Just 4) (appCostSum st) "")
                else "会话 ¥—"
    costTurnSeg = if pricesKnown && appLastCost st > 0
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

statusPeak :: AppState -> Text
statusPeak st = case appNow st of
  Just t | isOffPeak t -> "低峰"
  _ -> "高峰"

-- | 千分位分隔（21,444 而不是 21.4K），与参考实现的脚注一致。
