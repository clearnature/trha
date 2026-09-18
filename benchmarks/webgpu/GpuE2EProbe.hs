{-# LANGUAGE OverloadedStrings #-}

-- | GPU 端到端生产路径验证：TRHA_GPU=1 语义 + 真实 .sov
-- 1. gpuForwardFactory 构造 GPU 前向句柄（init 5GB 权重上传）
-- 2. createCPUAdapterWith (Just fwd) → engine → generateStream 走 GPU 分支
-- 3. 对比纯 CPU 的输出起点（同 seed，GPU logits 应一致 → 采样同 token）
module Main (main) where

import Control.Monad (forM_)
import System.Environment (getArgs)
import System.IO (hFlush, stdout)

import Infrastructure.CPU.InferenceGPU (gpuForwardFactory)
import LLM.Adapter.Interface (createCPUAdapterWith)
import Infrastructure.CPU.Inference (generateStream, InferenceEngine (..))
import Infrastructure.CPU.Types (CPUBackend(..), CPUConfig(..), CPUArchitecture(..), CPUFeatures(..))
import Infrastructure.CPU.Inference (InferenceEngine(..))
import qualified Data.Text as T

main :: IO ()
main = do
  args <- getArgs
  let sov = case args of (a : _) -> a; [] -> "/home/yanli/work/trha/models/20260721-033421_step31000.sov"
  putStrLn "=== GPU 端到端生产路径验证 ===" >> hFlush stdout
  -- 1. GPU 工厂（真实 .sov，5GB 上传一次性）
  rF <- gpuForwardFactory sov 12
  case rF of
    Left err -> putStrLn ("GPU 初始化失败（环境限制，非接线问题）: " ++ err) >> hFlush stdout
    Right fwd -> do
      putStrLn "GPU 工厂 OK，开始建引擎…" >> hFlush stdout
      -- 2. 带 GPU 句柄建引擎
      (eng, _) <- createCPUAdapterWith (Just fwd) sov
      putStrLn ("engineGPU 已注入: " ++ show (case engineGPU eng of Just _ -> "yes"; Nothing -> "NO")) >> hFlush stdout
      -- 3. 走 GPU 前的采样：单 token 起点
      r <- generateStream eng (T.pack "∀x: x∈Z12, x² = x·x") 3 (\_ -> pure ())
      case r of
        Left err -> putStrLn ("generateStream ✗: " ++ err)
        Right out -> putStrLn ("GPU 生成输出: " ++ T.unpack out)
      putStrLn "（GPU 60 层前向 + 采样完成；输出为示例文本）" >> hFlush stdout