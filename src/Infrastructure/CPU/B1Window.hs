-- | B1 因果窗口层（stream-trajectory-b1 #1：B1 层正式接入推理链）。
--
-- 语义与 benchmarks/cpu/B1TrajProbe.hs 的 b1Y 同构（抽取为正式模块）：
--   输入 = 6 个 token 的层 hidden（窗口，各 dim 维）
--   ① 每个 hidden 编码为节点 q_i ∈ {1,2,3}（encNode，签名 mod 3 聚合）
--   ② 邻接 adj[i][j] = q_i ⊗ q_j（GF3 乘）
--   ③ 传播 prop[d] = Σ_i vars[i][d] · adj[i][2]（对 Y 节点聚合）
--   ④ Y 槽残差更新：newY = prop ⊕ vars[2]（残差 ⊕）
-- 返回替换后的完整窗口（仅 Y 槽变化）。
module Infrastructure.CPU.B1Window
  ( b1WindowStep
  , b1ApplyWindow
  , b1YIndex
  ) where

import Infrastructure.CPU.GF3Intrinsic (tritMul)
import Infrastructure.CPU.SovereignTypes
  ( GF27, mkTrit, gf27ToInt, tritToInt )
import qualified Infrastructure.CPU.SovereignTypes as ST

-- | Y 节点在窗口内的槽位（与 B1TrajProbe/B1LmProbe 一致）。
b1YIndex :: Int
b1YIndex = 2

-- | 节点编码：hidden 前 8 维三值签名聚合到 {1,2,3}（与探针 encNode 逐位一致）。
encNode :: [GF27] -> Int
encNode n =
  let es = take 8 n
      sig = foldl (\acc e -> acc * 3 + (gf27ToInt e `mod` 3)) 0 es
      lo = sig `mod` 3; hi = (sig `div` 3) `mod` 3; t = (lo + hi) `mod` 3
  in if t == 0 then 1 else t

-- | 一步因果窗口更新：6-token 窗口（列宽对齐 dim）→ 替换 Y 槽（残差 ⊕）后的窗口。
--   窗口不足 6 时按头部补齐（重复第 0 个 hidden），保证输出长度 = 输入长度。
b1WindowStep :: Int -> [[GF27]] -> [[GF27]]
b1WindowStep dim hs
  | null hs   = []
  | otherwise = take yIdx padded ++ [newY] ++ drop (yIdx + 1) padded
  where
    yIdx = b1YIndex
    padded0 = take 6 hs
    padded = padded0 ++ replicate (6 - length padded0) (head padded0)
    vs :: [[GF27]]
    vs = map (take dim . (++ repeat ST.gf27Zero)) padded
    qs = map encNode vs
    adj :: [[Int]]
    adj = [ [ tritToInt (tritMul (mkTrit (qs !! i)) (mkTrit (qs !! j))) | j <- [0 .. 5] ]
          | i <- [0 .. 5] ]
    mulE v a = ST.mulGF27 v (ST.embedGF3 (mkTrit a))
    -- prop[d] = Σ_i vs[i][d] · adj[i][Y]（对 Y 节点聚合）
    prop :: [GF27]
    prop =
      [ foldl (\acc i -> ST.plusGF27 acc (mulE (vs !! i !! d) (adj !! i !! yIdx)))
              ST.gf27Zero [0 .. 5]
      | d <- [0 .. dim - 1] ]
    newY :: [GF27]
    newY = zipWith ST.plusGF27 prop (vs !! yIdx)

-- | 对整条 hidden 序列应用 B1 窗口层（协议对齐 B1TrajProbe：Y 槽 = 窗口 index 2）。
--   对每个位置 i，取窗口 [i-2 .. i+3]（头部越界用 hs!!0 补，尾部越界截断后按
--   'b1WindowStep' 头补规则补齐），位置 i 作为该窗口的 Y 槽，输出 = 更新后的 Y。
--   输出与输入同形；空序列返回空。
b1ApplyWindow :: Int -> [[GF27]] -> [[GF27]]
b1ApplyWindow _ [] = []
b1ApplyWindow dim hs = [ updated i | i <- [0 .. length hs - 1] ]
  where
    updated i =
      let win = [ if j < 0 || j >= length hs then head hs else hs !! j
                | j <- [i - 2 .. i + 3] ]     -- Y 槽（i）在窗口 index 2
      in b1WindowStep dim win !! b1YIndex
