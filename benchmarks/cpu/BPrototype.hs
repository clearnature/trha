-- | b 最小原型（2026-09-17）：把 causalGraphStep 的 6 节点传播改为「6 变量」——
-- nodes 不再来自单 x 的切片，而是每个变量一个独立向量（变量=token/cell 槽）。
-- 在合成 SCM-A（中介 X→Z→Y）/SCM-B（混杂 Z→X,Z→Y,X→Y）上验证：
--   干预 do(X=x) = 替换 X 变量的节点向量 → 传播 updated 是否随干预/观测可归因变化。
-- 复用真实传播逻辑（adj=q⊗k GF3 外积、prop=Σ node⊗adj、outProj、残差），
-- 仅改「节点来源」。判据：干预 vs 观测的 updated 有系统差异（下界：至少 1 维不同）。
module Main (main) where

import Control.Exception (evaluate)
import Infrastructure.CPU.SovereignTypes (GF27, Trit, mkGF27, mkTrit, gf27ToInt, tritToInt)
import Infrastructure.CPU.SovereignGF27 (gf27Matmul)
import Infrastructure.CPU.GF3Intrinsic (tritMul)
import qualified Infrastructure.CPU.SovereignTypes as ST

-- 6 变量 / dim=24 / hex=6 / nd=4 / heads=3（与 c4Layer 同缩比）
type Vars = [[GF27]]           -- 6 个变量，每变量 [GF27]（长 nd）

dimC, hexC, ndC, headsC :: Int
dimC = 24; hexC = 6; ndC = 4; headsC = 3

-- wuxing 关键权重（与 c4Layer 同构造法，确定性）
w3p :: Int -> Int -> Int -> [[Trit]]
w3p r c sd = [ [ mkTrit ((i * 7 + j * 13 + sd) `mod` 3) | j <- [0 .. c - 1] ] | i <- [0 .. r - 1] ]

nodeProj :: [[Trit]]   -- [dim, hex*nd] = [24, 24]
nodeProj = w3p dimC (hexC * ndC) 1
attnQ :: [[Trit]]       -- [nd, 1] = [4, 1]
attnQ = [ [mkTrit (1 + i * 2 `mod` 3)] | i <- [0 .. ndC - 1] ]  -- 首行非零：qi 反映变量
attnK' :: [[Trit]]
attnK' = [ [mkTrit 1] | _ <- [0 .. ndC - 1] ]           -- K 全 1：ki 随变量向量的 q 变
outProj :: [[Trit]]     -- [hex*nd, dim] = [24, 24]
outProj = w3p (hexC * ndC) dimC 4

scalarOf :: [GF27] -> Int
scalarOf (v : _) = gf27ToInt v `mod` 3
scalarOf []      = 0

-- 6 变量传播（镜像 causalGraphStep 但节点 = 变量向量）：
--   nodeH = nodeProj ⊗ concat var（[hex*nd]）→ 每变量 nd 切片
--   q_i = scalarOf(attnQ ⊗ var_i)；k_i = scalarOf(attnK ⊗ var_i)
--   adj[i][j] = q_i ⊗ k_j（GF3 外积）
--   prop[j] = Σ_i var_i ⊗ adj[i][j]；flat → outProj → 残差
graphStep :: Vars -> ([[Int]], [Int])
graphStep vars = (adj, updated)
  where
    -- 每个变量的 q/k 标量（attnQ/K 权重形状 [nd,1]：乘 var_i(nd) → 1 值）
    qs = [ scalarOf (gf27Matmul attnQ v) | v <- vars ]
    ks = [ scalarOf (gf27Matmul attnK' v) | v <- vars ]
    adj = [ [ tritMulInt (qs !! i) (ks !! j) | j <- [0 .. hexC - 1] ] | i <- [0 .. hexC - 1] ]
    tritMulInt a b = tritToInt (tritMul (mkTrit a) (mkTrit b))
    -- 图传播（镜像 causalGraphStep）：prop[j] = Σ_i var_i ⊗ adj[i][j]
    -- nodes 摊平 → outProj → 残差（输出在 Y 槽 = 第 4 变量）
    -- vars !! i 是第 i 变量的向量（[GF27] nd 长）；mulElem v a = v⊗a
    mulElem v a = ST.mulGF27 v (ST.embedGF3 (mkTrit a))
    prop = [ concatMap (\i -> map (\v -> mulElem v (adj !! i !! j)) (vars !! i)) [0 .. hexC - 1]
           | j <- [0 .. hexC - 1] ]
    flat = concat prop
    out  = gf27Matmul outProj (take dimC (flat ++ repeat ST.gf27Zero))
    updated = map gf27ToInt (zipWith ST.plusGF27 out (take dimC (concat vars ++ repeat ST.gf27Zero)))

-- 干预 do(X=x)：把第 0 个变量（X）的向量替换为 do 后编码
setVar :: Int -> [GF27] -> Vars -> Vars
setVar idx newV vars = take idx vars ++ [newV] ++ drop (idx + 1) vars

-- 确定性变量向量（不同变量不同值）
mkVar :: Int -> Int -> [GF27] -- idx 变量, 值 val（0..2）
mkVar idx val = [ mkGF27 ((val + 3 * idx + i) `mod` 27) | i <- [0 .. ndC - 1] ]

mkVars :: [Int] -> Vars -- [X值, Z值, Y值, ...]
mkVars seeds = [ mkVar i (seed) | (i, seed) <- zip [0 ..] seeds ]

-- SCM-A：观测 {X=1,Z=2}；干预 do(X=2)（替换 X）
-- SCM-B：观测 {Z=0,X=1}；干预 do(X=1) 且 Z 被替换为「观测 Z」或「无条件化」
main :: IO ()
main = do
  putStrLn "=== b 最小原型：6 变量图传播（变量=节点）==="
  -- 观测组 vs 干预组
  let obsA = mkVars [1, 2, 1, 0, 2, 1]     -- SCM-A 观测 X=1,Z=2（值 0..2）
      doA  = setVar 0 (mkVar 0 2) obsA        -- do(X=2)
      obsB = mkVars [1, 0, 1, 0, 2, 1]     -- SCM-B 观测 X=1,Z=0
      doB  = setVar 0 (mkVar 0 2) obsB        -- do(X=2)
      adjAObs = graphStep obsA
      adjADo  = graphStep doA
      adjBObs = graphStep obsB
      adjBDo  = graphStep doB
  -- 诊断：q/k 标量值（找 adj 全零根源）
  let qsA = [ scalarOf (gf27Matmul attnQ v) | v <- obsA ]
      ksA = [ scalarOf (gf27Matmul attnK' v) | v <- obsA ]
  putStrLn ("  [diag] obsA qs=" ++ show qsA ++ " ks=" ++ show ksA)
  let (adjAObs, updAObs) = graphStep obsA
      (adjADo, updADo) = graphStep doA
      (adjBObs, updBObs) = graphStep obsB
      (adjBDo, updBDo) = graphStep doB
      -- 条件化 Z：把 Z 槽（第 1 变量）替换为固定值（观测化，测 confounder/mediator 语义）
      condZA = setVar 1 (mkVar 1 1) obsA          -- SCM-A 条件 Z=1
      condZB = setVar 1 (mkVar 1 1) obsB          -- SCM-B 条件 Z=1
      (_, updAcond) = graphStep condZA
      (_, updBcond) = graphStep condZB
      yIdx = 4 * ndC                              -- Y 槽 = 第 4 变量（0-indexed 4）的起点
      ySlice u = take ndC (drop yIdx (take dimC (u ++ repeat 0)))
      updAObsY = ySlice updAObs; updADoY = ySlice updADo
      updBObsY = ySlice updBObs; updBDoY = ySlice updBDo
      updAcondY = ySlice updAcond; updBcondY = ySlice updBcond
  -- 诊断：q/k 标量值（找 adj 全零根源）
  let qsA = [ scalarOf (gf27Matmul attnQ v) | v <- obsA ]
      ksA = [ scalarOf (gf27Matmul attnK' v) | v <- obsA ]
  putStrLn ("  [diag] obsA qs=" ++ show qsA ++ " ks=" ++ show ksA)
  putStrLn ("  SCM-A 观测 adj0 = " ++ show (head adjAObs) ++ " … 干预 adj0 = " ++ show (head adjADo))
  putStrLn ("  SCM-B 观测 adj0 = " ++ show (head adjBObs) ++ " … 干预 adj0 = " ++ show (head adjBDo))
  putStrLn ("  A: 干预改变 adj? " ++ show (adjAObs /= adjADo) ++ "  Y槽更新? " ++ show (updAObsY /= updADoY))
  putStrLn ("  B: 干预改变 adj? " ++ show (adjBObs /= adjBDo) ++ "  Y槽更新? " ++ show (updBObsY /= updBDoY))
  putStrLn ("  A: 条件Z改变 Y槽? " ++ show (updAObsY /= updAcondY) ++ "（中介：条件 Z 应改变直接效应）")
  putStrLn ("  B: 条件Z改变 Y槽? " ++ show (updBObsY /= updBcondY) ++ "（混杂：条件 Z 应恢复效应）")
  putStrLn ("  A Y槽 obs=" ++ show updAObsY ++ " do=" ++ show updADoY ++ " condZ=" ++ show updAcondY)
  putStrLn ("  B Y槽 obs=" ++ show updBObsY ++ " do=" ++ show updBDoY ++ " condZ=" ++ show updBcondY)
  putStrLn ""
  putStrLn "  ⚠ 判据说明：此原型实现=「变量向量 → q/k → GF3 邻接」的直接映射；"
  putStrLn "    真实的干预应是「结构方程替换」而非「替换向量」——本步验证传播机制能否被"
  putStrLn "    变量级输入驱动（b 的可行性下限）。"
  _ <- evaluate (length adjAObs + length adjADo + length adjBObs + length adjBDo)
  pure ()