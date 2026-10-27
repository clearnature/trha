{-# LANGUAGE OverloadedStrings #-}

-- | GF(27) 整链前向 —— 把整个层体从 GF(3) 搬到 GF(3³) 上闭环。
--
-- 动机（M7h 的实测结论）：GF(3) 只有 3 个元素，装不下「音阶级数」
-- @Σtrits ∈ [0,12]@；当它 @≡ 0 (mod 3)@ 时被零因子抹平 —— 这正是 @dim=36@
-- 退化为不动点（@tailCycle = 1@）的根因。只换 'MixGF27' 不够，因为下游
-- @z3rMatmul@ 仍按 @% 3@ 归约；必须让 @matmul \/ rmsnorm \/ swiglu@ 全在 GF(27) 上。
--
-- 参考 @Sovereign.Algebra.GF27@（Agda，0 postulate）：
--
-- > GF27 = Trit × Trit × Trit，编码 a + 3b + 9c ↔ a + bα + cα²
-- > _+gf27_ (a,b,c) (d,e,f) = (a⊕d, b⊕e, c⊕f)      -- 逐分量 mod 3
-- > α³ = α + 2（alpha-cubed，refl）
-- > GF(27)* ≅ Z/26Z，生成元 α（阶 26，α¹³ = 2 = −1）
--
-- ⭐ 一处关键语义变化：归一化不再用 Q16 定点缩放，而是**沿 ⟨α⟩ 旋转**
-- （@x ⊗ α^m@，@m@ 由非零计数给出）。GF(27)* 是 26 阶循环群 —— 对应
-- 「泛音级联」的音级推进，也让每步都停在域内（有界且可逆）。
module Infrastructure.CPU.SovereignGF27
  ( gf27Zero
  , gf27One
  , gf27Alpha
  , gf27Add
  , gf27AddRef
  , gf27AddTable
  , gf27Neg
  , gf27AlphaPow
  , gf27Matmul
  , gf27MatmulZip
  , gf27RmsNorm
  , gf27RmsNormScalar
  , gf27SwiGLU
  , gf27SwiGLUScalar
  , phaseSeq27
  , embed27
  , layerIntrinsic27
  , layerIntrinsic27At
  , forwardIntrinsic27
  , traceStates27
  ) where

import Data.List (foldl')
import qualified Data.Vector.Unboxed as V
import Infrastructure.CPU.GF3Intrinsic (AlphaPower(..), DuodecPoint, gf27Decode, gf27Encode, gf27Mul)
import Infrastructure.CPU.SovereignIntrinsic
  ( MixMode(..)
  , SovereignIntLayer(..)
  , SovereignIntWeights(..)
  , christoffelInt
  )
import Infrastructure.CPU.SovereignModel (SovereignConfig(..), layerStep)
-- ⚠️ 只引入**类型与边界转换**，不引入同名算子（gf27Zero/gf27One 等在本模块
-- 已有 Int 版定义，公开 API 保持不变）。
import Infrastructure.CPU.SovereignTypes (GF27, Trit, gf27ToInt, mkGF27, mkTrit, tritToInt)

gf27Zero, gf27One, gf27Alpha :: Int
gf27Zero  = 0        -- (0,0,0)
gf27One   = 1        -- (1,0,0)
gf27Alpha = 3        -- (0,1,0)

-- | @_+gf27_@：逐分量 mod 3（**参考实现**）。
--
-- 保留作为 'gf27AddTable' 的建表源与对拍基线。
gf27AddRef :: Int -> Int -> Int
gf27AddRef x y = gf27Encode ((a1 + a2) `mod` 3, (b1 + b2) `mod` 3, (c1 + c2) `mod` 3)
  where
    (a1, b1, c1) = gf27Decode x
    (a2, b2, c2) = gf27Decode y

-- | 27×27 加法表（顶层 CAF，只构建一次）。
--
-- ⚡ 同理：每次加法 2×'gf27Decode' + 1×'gf27Encode' = 7 次除法 + 2 个元组；
-- `foldl' gf27Add` 每行跑 n 次，是 matmul 的第二热点。
gf27AddTable :: V.Vector Int
gf27AddTable = V.generate (27 * 27) (\i -> let (a, b) = i `divMod` 27 in gf27AddRef a b)

-- | @_+gf27_@（查表版）：逐分量 mod 3 的加法。
gf27Add :: Int -> Int -> Int
gf27Add x y = gf27AddTable V.! (x * 27 + y)

-- | 加法逆元（@negate@：各分量取负）。
gf27Neg :: Int -> Int
gf27Neg x = gf27Encode (neg3 a, neg3 b, neg3 c)
  where
    (a, b, c) = gf27Decode x
    neg3 v = (3 - v) `mod` 3

-- | @α^k@，@k@ 按 26 取模（@GF(27)* ≅ Z/26Z@，生成元 α，@α¹³ = −1@）。
gf27AlphaPow :: Int -> Int
gf27AlphaPow k = go (k `mod` 26) gf27One
  where
    go 0 acc = acc
    go n acc = go (n - 1) (gf27Mul acc gf27Alpha)

--------------------------------------------------------------------------------
-- GF(27) 上的三层算子
--------------------------------------------------------------------------------

-- | @Σ_j (w_j ⊗ x_j)@ —— __不归约到 GF(3)__，结果留在 27 个元素内。
--
-- ⚡ 性能：这里用严格累加 'foldl''。早先用惰性 'foldl' 时，`[1440,1440]` 规模下
-- 会累积 thunk 链，导致全 60 层真实权重跑不动。
-- ⚠️ 范畴：@w@ 是**权重**（GF(3) 元素 'Trit'），@x@ 是**激活**（GF(27) 元素）。
-- 体内仍是既有的 @Int@ 编码实现（'gf27Mul' 表版，已 benchmark）；类型化只发生在
-- 签名与边界，热路径一行未动。
gf27Matmul :: [[Trit]] -> [GF27] -> [GF27]
gf27Matmul w x = [ mkGF27 (rowDot gf27Zero (map tritToInt row) xi) | row <- w ]
  where
    xi = map gf27ToInt x
    -- 单趟融合：不分配 `zipWith gf27Mul row x` 的中间列表（原来是每行一次分配）。
    rowDot acc (a : as) (b : bs) = let acc' = gf27Add acc (gf27Mul a b) in acc' `seq` rowDot acc' as bs
    rowDot acc _        _        = acc

-- | 旧实现（'zipWith' + 'foldl''），保留作为对拍基线与基准对照。
gf27MatmulZip :: [[Trit]] -> [GF27] -> [GF27]
gf27MatmulZip w x =
  [ mkGF27 (foldl' gf27Add gf27Zero (zipWith gf27Mul (map tritToInt row) xi)) | row <- w ]
  where xi = map gf27ToInt x

-- | 归一化（**旧版：标量降维**，保留作对照）。
--
-- ⚠️ 这一版把整个向量塌缩到**一个标量** @shift = 非零计数@，
-- 再用它驱动全部 @dim@ 个分量沿 @⟨α⟩@ 旋转 —— **各分量的独立相位被抹平**。
-- 即「矢量被降维到标量」的典型位置。仅保留用于对照，不用于主路径。
gf27RmsNormScalar :: [GF27] -> [GF27] -> [GF27]
gf27RmsNormScalar gamma x =
  [ mkGF27 (gf27Mul (gf27Mul xj (gi !! (j `mod` length gamma))) (gf27AlphaPow shift))
  | (j, xj) <- zip [0 ..] xi ]
  where
    xi = map gf27ToInt x
    gi = map gf27ToInt gamma
    shift = length (filter (/= gf27Zero) xi)

-- | 归一化（**矢量版**）：**逐分量**沿 @⟨α⟩@ 旋转，旋转步数由**该分量自身**决定。
--
-- @x_j ↦ (x_j ⊗ γ_j) ⊗ α^[x_j ≠ 0]@ —— 每个分量携带自己的相位，不再共用一个全局标量。
-- 这是 GF(3)³ 矢量结构下的正确形态：变换是**逐分量**的，GF(3)-线性未被破坏。
gf27RmsNorm :: [GF27] -> [GF27] -> [GF27]
gf27RmsNorm gamma x =
  [ mkGF27 (gf27Mul (gf27Mul xj (gi !! (j `mod` length gamma)))
                    (gf27AlphaPow (if xj == gf27Zero then 0 else 1)))
  | (j, xj) <- zip [0 ..] xi ]
  where
    xi = map gf27ToInt x
    gi = map gf27ToInt gamma

-- | SwiGLU（**旧版：标量门控**，保留作对照）。
--
-- ⚠️ @gate = 非零计数 > 3@ 是**一个布尔标量**，整条 FFN 分支被它统一开/关，
-- 同样是把矢量塌缩成标量。仅保留用于对照。
gf27SwiGLUScalar :: [[Trit]] -> [[Trit]] -> [[Trit]] -> [GF27] -> [GF27]
gf27SwiGLUScalar gateW upW downW x = gf27Matmul downW gated
  where
    g = gf27Matmul gateW x
    u = gf27Matmul upW x
    gate = if length (filter (/= gf27Zero) (map gf27ToInt g)) > 3 then gf27One else gf27Zero
    gated = [ mulMk gate v | v <- u ]
    mulMk a b = mkGF27 (gf27Mul a (gf27ToInt b))

-- | SwiGLU（**矢量版**）：**逐分量门控** —— @gate_j@ 由 @g_j@ 自身决定。
--
-- @gated_j = gate_j ⊗ u_j@，@gate_j = g_j@（GF(27) 元素逐分量相乘）。
-- 不再有全局布尔把整条分支一起开/关。
gf27SwiGLU :: [[Trit]] -> [[Trit]] -> [[Trit]] -> [GF27] -> [GF27]
gf27SwiGLU gateW upW downW x = gf27Matmul downW gated
  where
    g = gf27Matmul gateW x
    u = gf27Matmul upW x
    gated = zipWith (\a b -> mkGF27 (gf27Mul (gf27ToInt a) (gf27ToInt b))) g u

--------------------------------------------------------------------------------
-- 层 / 前向（相位推进仍走 M7g 的 mixedOp）
--------------------------------------------------------------------------------

-- | 各层的相位状态：@(0,a0) →(T₁,a1)→ …@，周期 12。
phaseSeq27 :: SovereignConfig -> [DuodecPoint]
phaseSeq27 cfg = take (scDepth cfg) (iterate (\s -> fst (layerStep s)) (0, A0))

-- | GF(27) 域上的嵌入（token_embed 取模 3 后作为域元素 0..26 的低分量）。
embed27 :: SovereignConfig -> SovereignIntWeights -> [Int] -> [[GF27]]
embed27 cfg w tokenIds =
  [ take dim (row ++ repeat (mkGF27 gf27Zero))
  | tok <- tokenIds
  , let row = siwTokenEmbed w !! (tok `mod` length (siwTokenEmbed w)) ]
  where dim = scDim cfg

-- | 本源层体（GF(27) 版），由显式 @(cell, target)@ 驱动 —— 这样既可接 M7g 的
-- @DuodecPoint@，也可接 M8 的十二律相位（`SovereignPhase12`）。残差、归一化、FFN 全在域内闭环。
layerIntrinsic27At :: SovereignConfig -> SovereignIntLayer -> (Int, Int) -> [GF27] -> [GF27]
layerIntrinsic27At cfg lyr (cell, target) x = x2
  where
    addGF27 a b = mkGF27 (gf27Add (gf27ToInt a) (gf27ToInt b))
    heads = scHeads cfg
    dim   = scDim cfg
    gamma = replicate dim (mkGF27 gf27One)
    transported = gf27Matmul (silOutProj lyr)
                    (map mkGF27
                      (christoffelInt MixGF27 heads (silQProj lyr) (silPrototype lyr)
                                      cell target (map mkTrit (map gf27ToInt x))))
    x1 = gf27RmsNorm gamma (zipWith addGF27 x transported)
    ffnOut = gf27SwiGLU (silGateProj lyr) (silUpProj lyr) (silDownProj lyr) x1
    x2 = gf27RmsNorm gamma (zipWith addGF27 x1 ffnOut)

-- | 旧签名（M7g 路径，行为不变）：由 @DuodecPoint@ 推出 @(cell, target)@。
layerIntrinsic27 :: SovereignConfig -> SovereignIntLayer -> DuodecPoint -> [GF27] -> [GF27]
layerIntrinsic27 cfg lyr st = layerIntrinsic27At cfg lyr (snd (layerStep st))

-- | 端到端（GF(27)）：所有中间量与 logits 都 ∈ [0,26]。
forwardIntrinsic27 :: SovereignConfig -> SovereignIntWeights -> [Int] -> [[GF27]]
forwardIntrinsic27 cfg w tokenIds = map headLogits normed
  where
    dim = scDim cfg
    gamma = replicate dim (mkGF27 gf27One)
    embedded = embed27 cfg w tokenIds
    hidden = foldl (\hs (i, st) -> map (layerIntrinsic27 cfg (siwLayers w !! i) st) hs)
                   embedded (zip [0 ..] (phaseSeq27 cfg))
    bypassed = [ zipWith (\a b -> mkGF27 (gf27Add (gf27ToInt a) (gf27ToInt b))) h
                         (map (mkGF27 . tritToInt) (tableRow (siwContentBypass w) t))
               | (h, t) <- zip hidden tokenIds ]
    normed = map (gf27RmsNorm gamma) bypassed
    headLogits = gf27Matmul (siwLmHead w)
    tableRow table tok = take dim (table !! (tok `mod` length table) ++ repeat (mkTrit 0))

-- | 逐层状态轨迹（@depth + 1@ 帧），用于周期检测。
traceStates27 :: SovereignConfig -> SovereignIntWeights -> [Int] -> [[[GF27]]]
traceStates27 cfg w tokenIds =
  scanl (\hs (i, st) -> map (layerIntrinsic27 cfg (siwLayers w !! i) st) hs)
        (embed27 cfg w tokenIds)
        (zip [0 ..] (phaseSeq27 cfg))
