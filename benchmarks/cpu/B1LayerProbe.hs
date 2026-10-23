-- | B1 新因果层（推荐路线，j-mu67b8rm-ob2i）：不用 wuxing 权重，q/k 用确定性编码。
--
-- 输入 = 真实 60 层 hidden（sovereignForwardFullCompactReport 的层 hidden）。
-- 结构：6 变量（6 个 token 的 hidden 并排，每变量取 dim 全向量）→ 但 causalGraphStep
-- 的 6 节点从单个 x 切 6 片——B1 变体：变量 = token 的 hidden，节点 = 变量。
-- 即：6 个 token 的 hidden → enc(hidden_i) 签名 → q/k → adj → prop → out → Y 槽。
-- 干预 do(X=x) = 替换第 X 个 token 的 hidden。这是「变量=token 槽」的架构最小实现。
module Main (main) where

import Control.Exception (evaluate)
import System.Environment (getArgs)
import qualified Data.Vector.Storable as VS

import Infrastructure.CPU.SovereignFull
  ( loadWeightsSovC, loadWuxingFromSov, sovereignForwardFullCompactReport
  , SovereignIntWeightsC(..) )
import Infrastructure.CPU.SovereignModel (SovereignConfig(..))
import Infrastructure.CPU.SovereignWuxingLayer
  ( WuxingConfig(..) )
import Infrastructure.CPU.SovereignTypes (GF27, mkGF27, mkTrit, gf27ToInt, tritToInt)
import Infrastructure.CPU.SovereignGF27 (gf27Matmul)
import Infrastructure.CPU.GF3Intrinsic (tritMul)
import qualified Infrastructure.CPU.SovereignTypes as ST

cfg :: SovereignConfig
cfg = SovereignConfig { scDim = 1440, scDepth = 60, scHeads = 12
                      , scVocab = 1536, scFF = 4320, scEps = 1e-5 }

wcfg :: WuxingConfig
wcfg = WuxingConfig 1440 12 4 6 3

-- 节点签名编码（加密宽 v2）：8 分量 trit 签名 + 非零保证。
-- 8 分量 → 3^8 = 6561 空间，Z 槽的 tok2/tok8 差异更可能落到不同 trit 分区。
-- 编码：sig ∈ [0, 6560] → +1 强非零 → div 2187（=3^7，取最高位 trit）→ 0..2（0 换 1）
encNode :: [GF27] -> Int
encNode n =
  -- 双 trit 映射（不是单高位桶）：sig mod 3 与 (sig div 3) mod 3 混合，保留更多信息
  let es = take 8 n
      sig = foldl (\acc e -> acc * 3 + (gf27ToInt e `mod` 3)) 0 es
      lo = sig `mod` 3
      hi = (sig `div` 3) `mod` 3
      t  = (lo + hi) `mod` 3
  in if t == 0 then 1 else t

-- B1 因果层：vars = 6 个变量向量（token hidden）→ enc q/k → adj → prop → updated
graphB1 :: [[GF27]] -> [[GF27]] -> ([[Int]], [Int])
graphB1 vars projWeights = (adj, [])
  where
    dim = 1440; hex = 6
    qs = map encNode vars
    ks = map encNode vars
    adj = [ [ tritToInt (tritMul (mkTrit (qs !! i)) (mkTrit (ks !! j))) | j <- [0 .. hex - 1] ]
          | i <- [0 .. hex - 1] ]
    -- prop/out 暂留空：本步先验证 adj 层（干预/条件化 → q/k 签名变化）

main :: IO ()
main = do
  args <- getArgs
  let sov = case args of (a : _) -> a; [] -> "/home/yanli/work/trha/models/20260721-033421_step31000.sov"
  putStrLn "=== B1 新因果层：6 变量(=6 token hidden) × enc 编码 ==="
  ew <- loadWeightsSovC sov 12
  wlw <- loadWuxingFromSov sov 12 4 3
  case (ew, wlw) of
    (Left e, _) -> putStrLn ("weights ✗ " ++ e)
    (_, Left e) -> putStrLn ("wuxing ✗ " ++ e)
    (Right wc, Right wl) -> do
      -- 6 个 token = 6 变量：X=tok1, Z=tok2, Y=tok3, ...
      let obsToks = [1, 2, 3, 4, 5, 6]
          -- 干预 do(X)：X 是第 0 个 token → 替换为 tok7（不同值）
          doToks  = [7, 2, 3, 4, 5, 6]
      (logsO, structsO) <- sovereignForwardFullCompactReport cfg wc wcfg wl obsToks
      (logsD, structsD) <- sovereignForwardFullCompactReport cfg wc wcfg wl doToks
      let hO = map (\(h, _, _, _) -> h) structsO   -- 6 个变量 hidden
          hD = map (\(h, _, _, _) -> h) structsD
          qsO = map encNode hO; qsD = map encNode hD
          adjO = [ [ tritToInt (tritMul (mkTrit (qsO !! i)) (mkTrit (qsO !! j))) | j <- [0 .. 5] ] | i <- [0 .. 5] ]
          adjD = [ [ tritToInt (tritMul (mkTrit (qsD !! i)) (mkTrit (qsD !! j))) | j <- [0 .. 5] ] | i <- [0 .. 5] ]
      putStrLn ("  enc(obs)=" ++ show qsO)
      putStrLn ("  enc(do) =" ++ show qsD)
      putStrLn ("  B1: 干预改变 adj? " ++ show (adjO /= adjD))
      putStrLn ("  B1 adj0 obs=" ++ show (head adjO) ++ " do=" ++ show (head adjD))
      -- 条件化 Z：Z 是第 1 个 token → 替换为更远的 tok100（检验 enc 分辨力）
      let condToks = [1, 100, 3, 4, 5, 6]
      (_, structsC) <- sovereignForwardFullCompactReport cfg wc wcfg wl condToks
      let hC = map (\(h, _, _, _) -> h) structsC
          qsC = map encNode hC
          adjC = [ [ tritToInt (tritMul (mkTrit (qsC !! i)) (mkTrit (qsC !! j))) | j <- [0 .. 5] ] | i <- [0 .. 5] ]
      -- 诊断：tok2 vs tok8 的 hidden 差异分布（enc 为何盲）
      let hZ1 = hO !! 1                       -- 第 1 槽（Z 原 tok2）
          hZ2 = head hC                       -- 注意：condToks 换后 z 变 idx1 —— 取正确槽
      -- 直接对比 obs 第 1 槽 与 cond 第 1 槽
      let diffH = [ (gf27ToInt a - gf27ToInt b) `mod` 27
                  | (a, b) <- zip (hO !! 1) (hC !! 1) ]
          nonZeroDiff = length (filter (/= 0) diffH)
          diffHead = take 12 diffH
          maxDiff = if null diffH then 0 else maximum diffH
      putStrLn ("  [diagZ] obs-Z vs cond-Z: 非零差异=" ++ show nonZeroDiff
                ++ "/1440 前12=" ++ show diffHead ++ " max=" ++ show maxDiff)
      putStrLn ("  enc(condZ)=" ++ show qsC)
      putStrLn ("  B1: 条件Z 改变 adj? " ++ show (adjO /= adjC))
      _ <- evaluate (length logsO + length logsD + length adjO)
      pure ()