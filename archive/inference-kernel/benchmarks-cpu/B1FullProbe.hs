-- | B1Full：完整 B1 因果层接**真实层 hidden**（路径 A 第二部）。
--
-- B1LayerProbe 只验了 enc→adj（prop/out 留空）；本探针补全链路：
--   变量 = 6 个 token 的层 hidden（[GF27] 1440 维）
--   enc  = encNode（双 trit 签名，B1L 已验证分辨力）
--   adj  = q_i ⊗ k_j（GF3 外积，6×6）
--   prop[j] = Σ_i var_i ⊗ adj[i][j]（GF27 逐元素乘，1440 维）
--   Y 槽更新 = prop[Y] ⊕ var_Y（残差：Y 收到全部节点的消息；causalGraphStep 语义）
-- 判据（与 BPrototype 同构，但输入换成真实层 hidden）：
--   干预 do(X)、条件化 Z 都改变 adj；且二者产生的 Y 槽更新**互相不同**（非共线）。
module Main (main) where

import Control.Exception (evaluate)
import Control.Monad (forM_)
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

hexV :: Int
hexV = 6

-- 节点签名编码（与 B1LayerProbe / B1LProbe 相同）
encNode :: [GF27] -> Int
encNode n =
  let es = take 8 n
      sig = foldl (\acc e -> acc * 3 + (gf27ToInt e `mod` 3)) 0 es
      lo = sig `mod` 3
      hi = (sig `div` 3) `mod` 3
      t  = (lo + hi) `mod` 3
  in if t == 0 then 1 else t

-- B1 完整因果层：vars（6×1440）→ (adj 6×6, Y-slot 1440, full-prop 6×1440)
-- useProp=False（消融对照）：跳过 prop，Y 槽更新 = var_Y 原样
--   —— 判据：若 prop 是区分性的唯一来源，则 no-prop 下 Y 槽三向差异应全 0
b1full :: Bool -> [[GF27]] -> ([[Int]], [Int], [[Int]])
b1full useProp vars = (adj, yUpd, propI)
  where
    qs = map encNode vars
    ks = map encNode vars
    adj = [ [ tritToInt (tritMul (mkTrit (qs !! i)) (mkTrit (ks !! j))) | j <- [0 .. hexV - 1] ]
          | i <- [0 .. hexV - 1] ]
    -- prop[j][d] = Σ_i vars[i][d] ⊗ adj[i][j]（GF27 元素）
    mulE v a = ST.mulGF27 v (ST.embedGF3 (mkTrit a))
    prop =
      [ [ foldl (\acc i -> ST.plusGF27 acc (mulE (vars !! i !! d) (adj !! i !! j)))
                ST.gf27Zero [0 .. hexV - 1]
        | d <- [0 .. 1439] ]
      | j <- [0 .. hexV - 1] ]
    -- Y 槽 = 第 3 变量（index 2，中介 X→Z→Y 的 Y；BPrototype 约定 Y 槽 index 4，
    -- 这里 6 变量布局 [X,Z,Y,_,_,_] → Y 槽 index 2）
    yIdx = 2
    yProp = prop !! yIdx
    propI = map (map gf27ToInt) prop
    -- 残差：Y 槽更新 = prop[Y] ⊕ var_Y；消融时 = var_Y 原样
    yUpd
      | useProp  = [ ST.gf27ToInt (ST.plusGF27 a b) | (a, b) <- zip yProp (vars !! yIdx) ]
      | otherwise = map (gf27ToInt) (vars !! yIdx)

main :: IO ()
main = do
  args <- getArgs
  let sov = case args of (a : _) -> a; [] -> "/home/yanli/work/trha/models/20260721-033421_step31000.sov"
  putStrLn "=== B1Full 消融：prop on/off 的区分性归因（--no-prop 跳过 prop）==="
  ew <- loadWeightsSovC sov 12
  wlw <- loadWuxingFromSov sov 12 4 3
  case (ew, wlw) of
    (Left e, _) -> putStrLn ("weights ✗ " ++ e)
    (_, Left e) -> putStrLn ("wuxing ✗ " ++ e)
    (Right wc, Right wl) -> do
      let obsToks  = [1, 2, 3, 4, 5, 6]
          doToks   = [7, 2, 3, 4, 5, 6]      -- 干预 do(X)：X=第 0 槽
          condToks = [1, 100, 3, 4, 5, 6]    -- 条件化 Z：Z=第 1 槽
      (_, _, hO) <- sovereignForwardFullCompactReportL cfg wc wcfg wl obsToks
      (_, _, hD) <- sovereignForwardFullCompactReportL cfg wc wcfg wl doToks
      (_, _, hC) <- sovereignForwardFullCompactReportL cfg wc wcfg wl condToks
      let yNZ a b = length (filter (/= 0) (zipWith (-) a b))
          -- 黄金基线条：Y 槽原始 hidden（token 恒 3）在三种配置下应全同（逐 token 独立）
          rawYDiff1 = yNZ (map gf27ToInt (hO !! 2)) (map gf27ToInt (hD !! 2))
          rawYDiff2 = yNZ (map gf27ToInt (hO !! 2)) (map gf27ToInt (hC !! 2))
      putStrLn ("  [基线] Y 槽原始 hidden obs-vs-do 差异=" ++ show rawYDiff1
                ++ " obs-vs-cond=" ++ show rawYDiff2 ++ "（应 0：Y 槽 token 同、逐 token 独立）")
      forM_ [ (True, "prop"), (False, "no-prop") ] $ \(useP, tag) -> do
        let (adjO, yO, _) = b1full useP hO
            (adjD, yD, _) = b1full useP hD
            (adjC, yC, _) = b1full useP hC
        putStrLn ("  [" ++ tag ++ "] adj 三向: 干预?" ++ show (adjO /= adjD)
                  ++ " 条件?" ++ show (adjO /= adjC) ++ " 互异?" ++ show (adjD /= adjC))
        putStrLn ("  [" ++ tag ++ "] Y 槽三向: 干预?(" ++ show (yNZ yO yD) ++ "/1440)"
                  ++ " 条件?(" ++ show (yNZ yO yC) ++ "/1440)"
                  ++ " 互异?(" ++ show (yNZ yD yC) ++ "/1440)")
      -- 对照：no-prop 下若 Y 槽差异≈0 而 prop 下 >1300 ⟹ 区分性来自 prop（因果层核心）
      let (_, yO1, _) = b1full True hO; (_, yD1, _) = b1full True hD
          (_, yO0, _) = b1full False hO; (_, yD0, _) = b1full False hD
      putStrLn ("  【判定】prop 对 Y 槽差异的贡献: 干预 obs-vs-do prop="
                ++ show (yNZ yO1 yD1) ++ " no-prop=" ++ show (yNZ yO0 yD0))
      _ <- evaluate (length yO1 + length yD1 + length yO0)
      pure ()