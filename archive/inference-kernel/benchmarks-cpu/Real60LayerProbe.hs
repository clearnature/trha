-- | 真实 60 层紧凑 C 链 的**单 token 端到端计时**（墙钟，仅记录）。
--
-- 'loadWeightsSovC'（.sov → 'SovereignIntWeightsC' 紧凑 int32，≈5GB，绕开 40GB
-- 装箱与 CommitLimit 32GB）+ 'sovereignForwardFullCompact'（每 token 60 层 × 4
-- C matmul，OpenMP 18 线程）。
module Main (main) where

import Control.Exception (evaluate)
import GHC.Clock (getMonotonicTime)
import System.Environment (getArgs)

import Infrastructure.CPU.SovereignFull
  ( loadWeightsSovC, loadWuxingFromSov, sovereignForwardFullCompact
  , SovereignIntWeightsC )
import Infrastructure.CPU.SovereignModel (SovereignConfig(..))
import Infrastructure.CPU.SovereignWuxingLayer
  ( WuxingConfig(..), WuxingLayerW )
import Infrastructure.CPU.SovereignTypes (GF27)

timeIt :: IO a -> IO (a, Double)
timeIt act = do
  t0 <- getMonotonicTime
  r <- act
  t1 <- getMonotonicTime
  _ <- evaluate (r `seq` ())
  pure (r, (t1 - t0) * 1000)

cfg :: SovereignConfig
cfg = SovereignConfig { scDim = 1440, scDepth = 60, scHeads = 12
                      , scVocab = 1536, scFF = 4320, scEps = 1e-5 }

wcfg :: WuxingConfig
wcfg = WuxingConfig 1440 12 4 6 3

forwardFor :: SovereignIntWeightsC -> WuxingLayerW -> [Int] -> IO [[GF27]]
forwardFor wc wl tok = do
  r <- sovereignForwardFullCompact cfg wc wcfg wl tok
  _ <- evaluate (length (concat (map (map show) r)))
  pure r

main :: IO ()
main = do
  args <- getArgs
  let sov = case args of (a : _) -> a; [] -> "/home/yanli/work/trha/models/20260721-033421_step31000.sov"
  putStrLn "=== 真实 60 层紧凑 C 链：单 token 计时（墙钟仅记录）==="
  putStrLn (" .sov = " ++ sov)
  putStrLn " [load] 紧凑权重预载（≈5GB）…"
  (ew, tL) <- timeIt (loadWeightsSovC sov 12)
  (wlw, tW) <- timeIt (loadWuxingFromSov sov 12 4 3)
  putStrLn ("   [load] 紧凑权重 " ++ show (tL / 1000) ++ " s · wuxing " ++ show (tW / 1000) ++ " s（不计时）")
  case (ew, wlw) of
    (Left e, _) -> putStrLn ("  weights ✗: " ++ e)
    (_, Left e) -> putStrLn ("  wuxing ✗: " ++ e)
    (Right wc, Right wl) -> do
      let tok = [5]
      r1 <- forwardFor wc wl tok
      (_, tC1) <- timeIt (forwardFor wc wl tok)
      r2 <- forwardFor wc wl tok
      (_, tC2) <- timeIt (forwardFor wc wl tok)
      _ <- evaluate (r1 `seq` r2 `seq` ())
      putStrLn ("  [bench] C 双表 60 层 #1 = " ++ show tC1 ++ " ms/token")
      putStrLn ("  [bench] C 双表 60 层 #2 = " ++ show tC2 ++ " ms/token")
      putStrLn ("  一致性：#1 ≡ #2（同权重两次输出逐位比较）= " ++ show (r1 == r2))
      putStrLn ("  说明：权重常驻不重载；#1 含首次物化（惰性强制），#2 起为稳态。")