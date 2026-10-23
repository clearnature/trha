-- | P1 第一批探测（用户裁定口径）：wuxing 架构先验在零因果训练下的结构敏感性。
--
-- 3 次真实前向（真实 .sov 60 层 + wuxing data/1..21，'sovereignForwardFullCompactReport'）：
--   f1 = forward([tokX1])       -- 基准（X=1）
--   f2 = forward([tokZ2,tokX1]) -- 有 Z 历史（Z=2 先于 X=1）
--   f3 = forward([tokZ0,tokX1]) -- Z 值不同（Z=0 先于 X=1）
-- 每次记录 a) lm_head 完整 logits（非 argmax） b) wuxing 结构输出 (h, st, chain, oks)。
-- 断言：
--   A1: KL(logits1, logits2) < 0.001 ⇒ lm_head 逐 token 独立成立（bench3 复核）
--   A2: chain(1) ≠ chain(2) ⇒ wuxing 对历史敏感
--   A3: chain(2) ≠ chain(3) ⇒ wuxing 对 Z **值**敏感（区分长度 vs 因果敏感性，关键判据）
--
-- token id 选择：X=1 ⇒ tokX = 1；Z=2 ⇒ tokZ2 = 2；Z=0 ⇒ tokZ0 = 0（显式注入，
-- 全部 < vocab=1536 且互不相等，规避词法 hash）。
module Main (main) where

import Control.Exception (evaluate)
import System.Environment (getArgs)

import Infrastructure.CPU.SovereignFull
  ( loadWeightsSovC, loadWuxingFromSov, sovereignForwardFullCompactReport )
import Infrastructure.CPU.SovereignModel (SovereignConfig(..))
import Infrastructure.CPU.SovereignWuxingLayer
  ( WuxingConfig(..), WuxingLayerW, T6State )
import Infrastructure.CPU.SovereignTypes (GF27, gf27ToInt)

cfg :: SovereignConfig
cfg = SovereignConfig { scDim = 1440, scDepth = 60, scHeads = 12
                      , scVocab = 1536, scFF = 4320, scEps = 1e-5 }

wcfg :: WuxingConfig
wcfg = WuxingConfig 1440 12 4 6 3

-- logits → 概率分布（GF27 值非负，直接归一化）
probsOf :: [GF27] -> [Double]
probsOf xs =
  let vals = map (fromIntegral . gf27ToInt) xs
      tot  = sum vals
  in if tot <= 0 then replicate (length xs) (1 / fromIntegral (length xs))
     else map (/ tot) vals

-- KL 散度 P||Q
kl :: [Double] -> [Double] -> Double
kl p q = sum [ pv * log (pv / qv) | (pv, qv) <- zip p q, pv > 0 && qv > 0 ]

main :: IO ()
main = do
  args <- getArgs
  let sov = case args of (a : _) -> a; [] -> "/home/yanli/work/trha/models/20260721-033421_step31000.sov"
  putStrLn "=== P1 第一批：wuxing 架构先验的结构敏感性（3 前向）==="
  ew <- loadWeightsSovC sov 12
  wlw <- loadWuxingFromSov sov 12 4 3
  case (ew, wlw) of
    (Left e, _) -> putStrLn ("weights ✗ " ++ e)
    (_, Left e) -> putStrLn ("wuxing ✗ " ++ e)
    (Right wc, Right wl) -> do
      let runTok toks = do
            (logs, structs) <- sovereignForwardFullCompactReport cfg wc wcfg wl toks
            let lastLog = last logs
                (_, _, chain, oks) = last structs
            _ <- evaluate (length lastLog + length chain)
            pure (lastLog, chain, oks)
      -- 值维度（修正版，j-mu64zhv5-s5j9）：wuxing 是单向量函数 ⇒ 对「同变量不同值」敏感才是
      -- 因果载体在 wuxing 的必要条件。fB/fC = X=2/X=3（不同 token id，嵌入行不同 → hidden 不同）。
      (lg1, ch1, ok1) <- runTok [1]
      (lgB, chB, okB) <- runTok [2]
      (lgC, chC, okC) <- runTok [3]
      -- 历史维度（对照）：[Z,X] vs [X] —— 架构无跨 token 通路 ⇒ 预期无差异（印证 A1）
      (lg2, ch2, ok2) <- runTok [2, 1]
      let kl1B = kl (probsOf lg1) (probsOf lgB)
          kl1C = kl (probsOf lg1) (probsOf lgC)
          kl12 = kl (probsOf lg1) (probsOf lg2)
          valSens = ch1 /= chB || chB /= chC   -- 值敏感（关键）
          histSens = ch1 /= ch2                -- 历史敏感（预期 False）
      putStrLn ("  f1 forward([X=1])   chain=" ++ show ch1)
      putStrLn ("  fB forward([X=2])   chain=" ++ show chB)
      putStrLn ("  fC forward([X=3])   chain=" ++ show chC)
      putStrLn ("  f2 forward([Z=2,X=1]) chain=" ++ show ch2 ++ "（历史对照）")
      putStrLn ("  A1' KL[1→2]=" ++ show kl1B ++ " KL[1→3]=" ++ show kl1C ++ " KL[1→(2,1)]=" ++ show kl12)
      putStrLn ("  值敏感（f1/fB/fC chain 有差异）= " ++ show valSens ++ "  ← 因果载体在 wuxing 的必要条件")
      putStrLn ("  历史敏感（f1 vs f2 chain 差异）= " ++ show histSens ++ "  ← 预期 False（无跨 token 通路）")
      putStrLn ("      oks1=" ++ show ok1 ++ " oksB=" ++ show okB ++ " oksC=" ++ show okC)