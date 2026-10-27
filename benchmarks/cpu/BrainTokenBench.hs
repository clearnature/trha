-- | P-12 门禁探针：紧凑权重单 token 计时 + 常驻内存（仅记录，不阻断 CI）。
--
-- 路径：@loadWeightsSovC@（一次解包常驻，60 层 ≈5GB）→
--       @sovereignForwardFullCompact@（每 token 不重读 .sov、不重建 CIntLayer）。
--
-- 用法：
--   trha-cpu-braintoken [<model.sov>] [--tokens N]
-- 默认模型：~/.trha/models/20260721-033421_step31000.sov
-- 输出一行：
--   BRAINTOKEN load_ms=... warmup_ms=... token_ms=... rss_mb=... tokens=... device=cpu
--
-- 若模型不存在，打印 SKIP 并以 0 退出（CI 无权重时不应阻断）。
module Main (main) where

import Control.Exception (evaluate)
import Data.List (isPrefixOf)
import GHC.Clock (getMonotonicTime)
import System.Directory (doesFileExist, getHomeDirectory)
import System.Environment (getArgs)
import System.FilePath ((</>))

import Infrastructure.CPU.SovereignFull
  ( SovereignIntWeightsC(..)
  , loadWeightsSovC
  , loadWuxingFromSov
  , sovereignForwardFullCompact
  )
import Infrastructure.CPU.SovereignModel (SovereignConfig(..))
import Infrastructure.CPU.SovereignWuxingLayer (WuxingConfig(..), WuxingLayerW)

cfg :: SovereignConfig
cfg = SovereignConfig
  { scDim = 1440, scDepth = 60, scHeads = 12
  , scVocab = 1536, scFF = 4320, scEps = 1e-5 }

wcfg :: WuxingConfig
wcfg = WuxingConfig 1440 12 4 6 3

timeIt :: IO a -> IO (a, Double)
timeIt act = do
  t0 <- getMonotonicTime
  r <- act
  _ <- evaluate r
  t1 <- getMonotonicTime
  pure (r, (t1 - t0) * 1000)

-- | Force the whole logits list (otherwise only WHNF is timed).
timeItList :: IO [[a]] -> IO ([[a]], Double)
timeItList act = do
  t0 <- getMonotonicTime
  r <- act
  _ <- evaluate (sum (map length r))
  t1 <- getMonotonicTime
  pure (r, (t1 - t0) * 1000)

readRssMb :: IO Int
readRssMb = do
  s <- readFile "/proc/self/status"
  pure $ case [ w | l <- lines s, "VmRSS:" `isPrefixOf` l
                  , w <- words l, not (null w), all (`elem` "0123456789") w ] of
    (x : _) -> read x `div` 1024
    []      -> 0

main :: IO ()
main = do
  args <- getArgs
  home <- getHomeDirectory
  let defaultSov = home </> ".trha" </> "models" </> "20260721-033421_step31000.sov"
      sov = case [ a | a <- args, not ("--" `isPrefixOf` a) ] of
              (a : _) -> a
              []      -> defaultSov
      tokens = case [ read n
                    | a <- args, "--tokens=" `isPrefixOf` a
                    , let n = drop (length ("--tokens=" :: String)) a ] of
                 (n : _) -> n
                 []      -> 3
  exists <- doesFileExist sov
  if not exists
    then putStrLn ("SKIP: model not found: " ++ sov)
    else do
      (ew, loadMs) <- timeIt (loadWeightsSovC sov 12)
      case ew of
        Left e -> putStrLn ("FAIL: loadWeightsSovC: " ++ e)
        Right wc -> do
          wlR <- loadWuxingFromSov sov 12 4 3
          case wlR of
            Left e -> putStrLn ("FAIL: loadWuxingFromSov: " ++ e)
            Right wl -> do
              -- 预热（首次调用含表初始化/缓存冷启动）
              (_, warmMs) <- timeItList (sovereignForwardFullCompact cfg wc wcfg wl [1])
              (_, totalMs) <- timeItList
                (mapM (\_ -> sovereignForwardFullCompact cfg wc wcfg wl [1]) [1 .. tokens])
              rss <- readRssMb
              let perToken = totalMs / fromIntegral (max 1 tokens)
              putStrLn $ "BRAINTOKEN load_ms=" ++ show (round loadMs :: Int)
                ++ " warmup_ms=" ++ show (round warmMs :: Int)
                ++ " token_ms=" ++ show (round perToken :: Int)
                ++ " rss_mb=" ++ show rss
                ++ " tokens=" ++ show tokens
                ++ " device=cpu"
