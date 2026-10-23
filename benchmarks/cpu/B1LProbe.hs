-- | B1L：用**真实层 hidden**（60 层后、wuxing 前）测 B1 因果层的可区分性。
--
-- 背景（j-mu6cjfaj-gbeu 路径 A / 上次交接）：B1LayerProbe 取的是 'structs' 里的 @h@
-- ——那是 wuxingForward 之余。真实层 hidden（'layerIntrinsic27C' fold 直接产出）才是
-- 新因果层应插入的位置。本探针把同一套干预/条件化诊断换到层 hidden 上跑：
--   变量 = token 槽（6 个 token），hidden = 该 token 的层 hidden
--   干预 do(X=x)  = 替换第 0 个 token
--   条件化 Z     = 替换第 1 个 token
-- 判据：层 hidden 上干预/条件化仍能改变 enc 签名 → adj 变化 → 可区分。
module Main (main) where

import Control.Exception (evaluate)
import System.Environment (getArgs)
import qualified Data.Vector.Storable as VS

import Infrastructure.CPU.SovereignFull
  ( loadWeightsSovC, loadWuxingFromSov, sovereignForwardFullCompactReportL )
import Infrastructure.CPU.SovereignModel (SovereignConfig(..))
import Infrastructure.CPU.SovereignWuxingLayer ( WuxingConfig(..) )
import Infrastructure.CPU.SovereignTypes (GF27, mkTrit, gf27ToInt, tritToInt)
import Infrastructure.CPU.GF3Intrinsic (tritMul)
import qualified Infrastructure.CPU.SovereignTypes as ST

cfg :: SovereignConfig
cfg = SovereignConfig { scDim = 1440, scDepth = 60, scHeads = 12
                      , scVocab = 1536, scFF = 4320, scEps = 1e-5 }

wcfg :: WuxingConfig
wcfg = WuxingConfig 1440 12 4 6 3

-- 节点签名编码（与 B1LayerProbe 相同：双 trit 映射，0→1 防退化）
encNode :: [GF27] -> Int
encNode n =
  let es = take 8 n
      sig = foldl (\acc e -> acc * 3 + (gf27ToInt e `mod` 3)) 0 es
      lo = sig `mod` 3
      hi = (sig `div` 3) `mod` 3
      t  = (lo + hi) `mod` 3
  in if t == 0 then 1 else t

adjFrom :: [[GF27]] -> [[Int]]
adjFrom hs =
  let qs = map encNode hs
  in [ [ tritToInt (tritMul (mkTrit (qs !! i)) (mkTrit (qs !! j))) | j <- [0 .. 5] ]
     | i <- [0 .. 5] ]

main :: IO ()
main = do
  args <- getArgs
  let sov = case args of (a : _) -> a; [] -> "/home/yanli/work/trha/models/20260721-033421_step31000.sov"
  putStrLn "=== B1L：真实层 hidden（wuxing 前）× B1 因果层编码 ==="
  ew <- loadWeightsSovC sov 12
  wlw <- loadWuxingFromSov sov 12 4 3
  case (ew, wlw) of
    (Left e, _) -> putStrLn ("weights ✗ " ++ e)
    (_, Left e) -> putStrLn ("wuxing ✗ " ++ e)
    (Right wc, Right wl) -> do
      let obsToks = [1, 2, 3, 4, 5, 6]
          doToks  = [7, 2, 3, 4, 5, 6]        -- 干预 do(X=tok7)
          condToks = [1, 100, 3, 4, 5, 6]     -- 条件化 Z=tok100
      (_, _, hO) <- sovereignForwardFullCompactReportL cfg wc wcfg wl obsToks
      (_, _, hD) <- sovereignForwardFullCompactReportL cfg wc wcfg wl doToks
      (_, _, hC) <- sovereignForwardFullCompactReportL cfg wc wcfg wl condToks
      let qsO = map encNode hO; qsD = map encNode hD; qsC = map encNode hC
          adjO = adjFrom hO; adjD = adjFrom hD; adjC = adjFrom hC
      putStrLn ("  enc(layer obs)=" ++ show qsO)
      putStrLn ("  enc(layer do) =" ++ show qsD)
      putStrLn ("  enc(layer condZ)=" ++ show qsC)
      putStrLn ("  B1L: 层hidden 干预改变 adj? " ++ show (adjO /= adjD))
      putStrLn ("  B1L: 层hidden 条件Z 改变 adj? " ++ show (adjO /= adjC))
      putStrLn ("  B1L adj0 obs=" ++ show (head adjO)
                ++ " do=" ++ show (head adjD)
                ++ " cond=" ++ show (head adjC))
      -- 诊断：obs vs do 的层 hidden 差异（交换到 wuxing 前的差异分布）
      let diffHD = [ (gf27ToInt a - gf27ToInt b) `mod` 27
                   | (a, b) <- zip (hO !! 0) (hD !! 0) ]
          nzD = length (filter (/= 0) diffHD)
      putStrLn ("  [diag] X 槽 obs-vs-do 层hidden 非零差异=" ++ show nzD ++ "/1440")
      let diffHC = [ (gf27ToInt a - gf27ToInt b) `mod` 27
                   | (a, b) <- zip (hO !! 1) (hC !! 1) ]
          nzC = length (filter (/= 0) diffHC)
      putStrLn ("  [diag] Z 槽 obs-vs-cond 层hidden 非零差异=" ++ show nzC ++ "/1440")
      _ <- evaluate (length hO + length hD + length qsO)
      pure ()