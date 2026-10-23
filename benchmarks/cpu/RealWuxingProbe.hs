-- | b 真实性试金石：真实 wuxing 权重（data/1..21）下，6 变量图传播是否被激活。
--
-- 真实权重结构（M18）：nodeProj[1440,1440] → nodeH[1440] → 6 节点 × nd=240 切片，
-- attnQ/K[240,1] → 每节点标量，outProj[1440,1440]。天然就是「6 变量」。
-- 接入：6 变量向量（每段 240，首元素=变量值）concat 成 x；干预 do(X=x) = 替换 X 段。
-- causalGraphStep 原样跑（零改造）。判定：① q/k 是否非零（节点选择激活？）
-- ② 干预 vs 观测的 adj/updated 是否有差异（Y 槽 = 第 4 段）。
module Main (main) where

import Control.Exception (evaluate)
import System.Environment (getArgs)
import qualified Data.Vector.Storable as VS

import Infrastructure.CPU.SovereignWuxingLayer
  ( WuxingConfig(..), WuxingLayerW(..), causalGraphStep, argMaxIdx )
import Infrastructure.CPU.SovereignFull (loadWuxingFromSov)
import qualified Infrastructure.CPU.SovereignTypes as ST
import Infrastructure.CPU.SovereignTypes (GF27, Trit, mkGF27, mkTrit, gf27ToInt, tritToInt)
import Infrastructure.CPU.SovereignGF27 (gf27Matmul)
import Infrastructure.CPU.GF3Intrinsic (tritMul)

cfg :: WuxingConfig
cfg = WuxingConfig 1440 12 4 6 3

-- 变量向量：nd=240 长，**所有分量都携带变量值**（值 1/2 → GF27 域元素），
-- 且对相邻值（1 vs 2）在 mod 3 下也可区分（用 9*val 让值差异到 trit 高位）
mkVar :: Int -> Int -> [GF27]
mkVar idx val = [ mkGF27 ((9 * val + 3 * idx + i) `mod` 27) | i <- [0 .. 239] ]

-- 6 变量 concat：段序 [X,Z,Y,W,U,V]
mkX :: [Int] -> [GF27]
mkX vals = concat [ mkVar i v | (i, v) <- zip [0 ..] vals ]

-- 干预 do(X=x)：替换第 0 段（0..239）为值 x 的向量
doX :: [GF27] -> [GF27] -> [GF27]
doX newX xs = take 240 newX ++ drop 240 xs

-- Y 槽 = 第 4 段（idx 4 * 240 .. 4*240+239），返回 GF27 值
ySlice :: [GF27] -> [Int]
ySlice u = take 6 (drop (4 * 240) (map gf27ToInt (take 1440 (u ++ repeat (mkGF27 0)))))

-- 路径 A 完整传播：nodeH（真实 nodeProj）→ enc 编码 q/k → adj → prop → outProj → 残差
-- （替代 causalGraphStep 的 attnQ/K 投影——那是退化的）
-- encNode：多分量签名 + 非零保证。
-- 节点 n 取前 3 个 element 的 trit（mod 3），组合成 0..26 → +1 强非零 → mod 27，
-- 再映射到 GF3（div 9 → 0..2 其中 0 换 1）。目标是：不同节点值 → 不同签名，
-- 且保证 q/k 非零（边可传播）而不抹平 obs/do 差异。
encNode :: [GF27] -> Int
encNode n =
  let es = take 3 n
      sig = foldl (\acc e -> acc * 3 + (gf27ToInt e `mod` 3)) 0 es   -- 27 签名
      v = (sig + 1) `mod` 27
      t = v `div` 9                                              -- 高阶 trit 0..2
  in if t == 0 then 1 else t

graphA :: WuxingLayerW -> [GF27] -> ([[Int]], [Int])
graphA wl x = (adj, updated)
  where
    dim = 1440; hex = 6; nd = 240
    nodeH = gf27Matmul (wlNodeProj wl) x
    nodes = [ take nd (drop (i * nd) nodeH) | i <- [0 .. hex - 1] ]
    qs = map encNode nodes; ks = map encNode nodes
    adj = [ [ tritToInt (tritMul (mkTrit (qs !! i)) (mkTrit (ks !! j))) | j <- [0 .. hex - 1] ]
          | i <- [0 .. hex - 1] ]
    mulElem v a = ST.mulGF27 v (ST.embedGF3 (mkTrit a))
    prop = [ concatMap (\i -> map (\v -> mulElem v (adj !! i !! j)) (nodes !! i)) [0 .. hex - 1]
           | j <- [0 .. hex - 1] ]
    flat = concat prop
    out  = gf27Matmul (wlOutProj wl) (take dim (flat ++ repeat ST.gf27Zero))
    updated = map gf27ToInt (zipWith ST.plusGF27 out (take dim (x ++ repeat ST.gf27Zero)))

main :: IO ()
main = do
  args <- getArgs
  let sov = case args of (a : _) -> a; [] -> "/home/yanli/work/trha/models/20260721-033421_step31000.sov"
  putStrLn "=== b 真实性试金石：真实 wuxing 权重 × 6 变量图传播 ==="
  wlw <- loadWuxingFromSov sov 12 4 3
  case wlw of
    Left e -> putStrLn ("  loadWuxingFromSov ✗: " ++ e)
    Right wl -> do
      let obs  = mkX [1, 2, 1, 0, 2, 1]      -- X=1,Z=2（值 0..2）
          doV  = doX (mkVar 0 2) obs          -- do(X=2)
          (adjO, updO) = causalGraphStep cfg wl obs
          (adjD, updD) = causalGraphStep cfg wl doV
          -- 条件化 Z：替换第 1 段为固定值
          condZ = take 240 obs ++ take 240 (mkVar 1 1) ++ drop 480 obs
          (_, updC) = causalGraphStep cfg wl condZ
      -- 路径 A：q/k 用 nodeH 的确定性非零编码（取每节点首元素 mod 3 + 1，避开 0）
      let nodeH = gf27Matmul (wlNodeProj wl) obs
          nodes = [ take 240 (drop (i * 240) nodeH) | i <- [0 .. 5] ]
          enc n = ((gf27ToInt (head n) `div` 3) + 1) `mod` 3  -- 高阶 trit（div 3）：24→8→0+1=1, 12→4→1+1=2 区分
          qs = map enc nodes; ks = map enc nodes
          -- 用编码后的 q/k 重算 adj（替代 attnQ/attnK 投影）
          adjA = [ [ tritToInt (tritMul (mkTrit (qs !! i)) (mkTrit (ks !! j))) | j <- [0 .. 5] ] | i <- [0 .. 5] ]
      let adjOK = adjO /= adjD
      putStrLn ("  [路径A] qs=" ++ show qs ++ " 路径A adj0=" ++ show (head adjA))
      putStrLn ("  adj 观测 前2行 = " ++ show (take 2 adjO))
      putStrLn ("  adj 干预 前2行 = " ++ show (take 2 adjD))
      putStrLn ("  A: 干预改变 adj? " ++ show (adjO /= adjD))
      putStrLn ("  B: 干预改变 Y槽? " ++ show (ySlice updO /= ySlice updD))
      putStrLn ("  C: 条件Z 改变 Y槽? " ++ show (ySlice updO /= ySlice updC))
      putStrLn ("  Y槽 obs=" ++ show (take 6 (ySlice updO)) ++ " do=" ++ show (take 6 (ySlice updD))
                ++ " condZ=" ++ show (take 6 (ySlice updC)))
      let nodeHD = gf27Matmul (wlNodeProj wl) doV
          nodesD = [ take 240 (drop (i * 240) nodeHD) | i <- [0 .. 5] ]
          qsD = map enc nodesD
          ksD = map enc nodesD          -- k 也用 do 的节点（各自独立编码）
          adjAD = [ [ tritToInt (tritMul (mkTrit (qsD !! i)) (mkTrit (ksD !! j))) | j <- [0 .. 5] ] | i <- [0 .. 5] ]
      let diffN = [ (gf27ToInt (nodeHD !! i) - gf27ToInt (nodeH !! i)) `mod` 27 | i <- [0 .. 11] ]
      putStrLn ("  [diag2] obs/do 的 nodeH 前12差异=" ++ show diffN)
      -- ⭐ 路径 A 完整传播判据（graphA：真实 nodeProj/outProj + enc 编码 q/k）
      let (adjA2, updA2) = graphA wl obs
          (adjD2, updD2) = graphA wl doV
          (_, updC2) = graphA wl condZ
          yO = ySliceV updA2; yD = ySliceV updD2; yC = ySliceV updC2
      putStrLn ("  [路径A-完整] 干预改变 adj? " ++ show (adjA2 /= adjD2))
      -- prop 诊断：Y 段（节点 4）的入边是否非零、outProj 后 Y 段输入差异
      let (adjA3, _) = graphA wl obs
          yInO = [ adjA3 !! i !! 4 | i <- [0 .. 5] ]   -- Y 节点的入边（列 4）
      putStrLn ("  [diagY] adj 的 Y 列（入边）=" ++ show yInO)
      putStrLn ("  [路径A-完整] 干预改变 Y槽? " ++ show (yO /= yD))
      putStrLn ("  [路径A-完整] 条件Z 改变 Y槽? " ++ show (yO /= yC))
      putStrLn ("       Y槽 obs=" ++ show yO ++ " do=" ++ show yD ++ " condZ=" ++ show yC)
      _ <- evaluate (length adjO + length adjD + length updA2)
      pure ()

-- Y 槽切片（[Int] updated 版）
ySliceV :: [Int] -> [Int]
ySliceV u = take 6 (drop (4 * 240) (take 1440 (u ++ repeat 0)))