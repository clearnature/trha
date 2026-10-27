{-# LANGUAGE OverloadedStrings #-}

-- | InferenceGPU 集成验证：gpuForwardHidden（GPU-only 60 层闭环）hidden
-- 与 CPU 权威 reportL 逐元素对拍。验证 goLayers GPU-only 重构没破坏正确性。
module Main (main) where

import GHC.Clock (getMonotonicTime)
import Control.Exception (evaluate)

import System.Environment (getArgs)

import Infrastructure.CPU.InferenceGPU (GpuForward (..), initGpuForward, gpuForwardHidden)
import Infrastructure.CPU.SovereignModel (SovereignConfig (..))
import Infrastructure.CPU.SovereignFull (sovereignForwardFullCompactReportL, loadWuxingFromSov)
import Infrastructure.CPU.SovereignWuxingLayer (WuxingConfig (..))
import Infrastructure.CPU.SovereignTypes (gf27ToInt)

cfg0 :: SovereignConfig
cfg0 = SovereignConfig { scDim = 1440, scDepth = 60, scHeads = 12, scVocab = 1536, scFF = 4320 }

main :: IO ()
main = do
  args <- getArgs
  let sov = case args of (a : _) -> a; [] -> "/home/yanli/work/trha/models/20260721-033421_step31000.sov"
  putStrLn "=== InferenceGPU 集成验证（GPU-only 60 层 vs CPU reportL）==="
  rG <- initGpuForward sov 12
  case rG of
    Left err -> putStrLn ("initGpuForward ✗（环境限制）: " ++ err)
    Right gfw -> do
      ewl <- loadWuxingFromSov sov 12 4 3
      case ewl of
        Left err -> putStrLn ("loadWuxingFromSov ✗: " ++ err)
        Right wl -> do
          cp <- sovereignForwardFullCompactReportL cfg0 (gfWeights gfw) (wc12) wl [0]
          let want = map gf27ToInt (head (thd3 cp))
          t0 <- getMonotonicTime
          h <- gpuForwardHidden gfw (gfWeights gfw) [0]
          t1 <- getMonotonicTime
          _ <- evaluate (length (either (const []) id h))
          case h of
            Left err -> putStrLn ("gpuForwardHidden ✗: " ++ err)
            Right hidden -> do
              let got = map gf27ToInt (head hidden)
                  bad = [ (i, g, w) | (i, (g, w)) <- zip [0 :: Int ..] (zip got want), g /= w ]
              putStrLn ("GPU-only 60 层墙钟: " ++ show ((t1 - t0) * 1000) ++ " ms（含 init 后单 token）")
              putStrLn ("CPU 前 6: " ++ show (take 6 want) ++ "，GPU 前 6: " ++ show (take 6 got))
              if null bad
                then putStrLn "✓ InferenceGPU GPU-only 60 层与 CPU reportL 逐元素一致"
                else putStrLn ("✗ 不一致 " ++ show (length bad) ++ " 处（前 6: " ++ show (take 6 bad) ++ "）")
  where
    thd3 (_, _, c) = c
    wc12 = WuxingConfig 1440 12 4 6 3
    snd2 (_, t) = t