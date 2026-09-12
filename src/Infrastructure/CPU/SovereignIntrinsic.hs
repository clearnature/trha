{-# LANGUAGE OverloadedStrings #-}

-- | 纯整数（trit）前向 —— 把 'Infrastructure.CPU.GF3Intrinsic' 的本源算子接整条链路。
--
-- 与 "SovereignModel" 的关系：那边是__浮点__前向（对应 Python/torch 参考，
-- 即 @Sovereign\/Projection.agda@ 说的"电性文明退化投影"，数值会爆到 ~1e21）；
-- 这边每一步都 @% 3@ 归约，状态空间 @3^dim@ 有限 ⟹ 数值有界且必然周期。
--
-- 四处与浮点版的实质区别（全部来自 @sov-math@ 的 C++ 参考）：
--
-- > 线性层    z3rMatmul    Σ GF(3)乘 后 % 3       （浮点版 ternaryLinear 是实数乘）
-- > 归一化    z3rRmsNorm   Q16 定点 + % 3         （浮点版保留实数）
-- > FFN       z3rSwiGLU    gate 用非零计数判定、gated 用 GF(3) 乘
-- > 残差      tritAdd      (a+b) % 3              （浮点版 zipWith (+)）
--
-- ⚠️ 本文件经历了一次事故性清空（2026-09-12），此版本为**重建**：
--    材料 = ① @dist-newstyle/...\/SovereignIntrinsic.hi@ 的 import 与接口
--           ② 会话转录中 @grep -n@ 的原文片段（第 96–160 行完整）
--           ③ @SovereignModel.hs@（浮点版）的结构对照
--    重建时一并施加了「类型严格化」迁移（见下）。
--
-- ⚠️ 类型严格化（范畴隔离，见 'Infrastructure.CPU.SovereignTypes'）：
--    权重 = GF(3) 元素 'Trit'；激活 = trit 向量；@MixGF27@ 分支用 GF(27) 元素。
--    注意 'christoffelInt' 的返回类型仍是 @[Int]@ —— 因为 @MixLayer2@ 分支
--    返回 [0,24]（层2 整数累加，3 ≠ 0），范畴随 'MixMode' 而变，不是疏忽。
module Infrastructure.CPU.SovereignIntrinsic
  ( MixMode(..)
  , SovereignIntLayer(..)
  , SovereignIntWeights(..)
  , tritAdd
  , christoffelInt
  , layerIntrinsic
  , embedIntrinsic
  , phaseStates
  , forwardIntrinsic
  , traceStates
  ) where

import Infrastructure.CPU.Christoffel (transportTryte)
import Infrastructure.CPU.GF3Intrinsic
import Infrastructure.CPU.S2Geometry (getDirection, gf3Shift)
import Infrastructure.CPU.SovereignModel (SovereignConfig(..), layerStep)
import Infrastructure.CPU.SovereignTypes (GF27, Trit, mkTrit, gf27ToInt, tritToInt)

--------------------------------------------------------------------------------
-- 权重载体
--------------------------------------------------------------------------------

-- | 一层的权重。
--
-- ⚠️ 范畴：@sil*@ 都是**权重**，GF(3) 元素 'Trit'（值 0..2）。
-- 它们进入 GF(27) 运算前必须经 'embedGF3' 提升（Agda 的 @embed-gf3-gf27@）。
data SovereignIntLayer = SovereignIntLayer
  { silQProj     :: [[Trit]]      -- ^ [heads*6 × dim]
  , silOutProj   :: [[Trit]]      -- ^ [dim × dim]
  , silGateProj  :: [[Trit]]      -- ^ [ff × dim]
  , silUpProj    :: [[Trit]]      -- ^ [ff × dim]
  , silDownProj  :: [[Trit]]      -- ^ [dim × ff]
  , silPrototype :: [[[Trit]]]    -- ^ [heads][cells][6]
  } deriving (Show, Eq)

-- | 权重集合。
--
-- ⚠️ @siwTokenEmbed@ 等是**嵌入**（激活侧），范畴是 GF(27) 元素 'GF27'；
-- 与 @sil*@（权重侧 'Trit'）不同。
data SovereignIntWeights = SovereignIntWeights
  { siwTokenEmbed    :: [[GF27]]   -- ^ [vocab][dim] —— **嵌入**（激活侧），GF(27) 元素
  , siwContentBypass :: [[Trit]]   -- ^ [vocab][dim] —— **权重**，GF(3) 元素
  , siwLmHead        :: [[Trit]]   -- ^ [vocab][dim] —— **权重**，GF(3) 元素
  , siwLayers        :: [SovereignIntLayer]
  } deriving (Show, Eq)

-- | GF(3) 上的加法：@(a + b) mod 3@。
tritAdd :: Trit -> Trit -> Trit
tritAdd a b = mkTrit (tritToInt a + tritToInt b)

--------------------------------------------------------------------------------
-- head 混合方式
--------------------------------------------------------------------------------

-- | head 混合的方式。@Σtrits/6@ 在参考里是**泛音级联**的音阶位置（一个 tryte
-- = 6 个 trit = 一个音级），所以"怎么把它塌成 GF(3)"有三种可能：
--
-- > MixMod3    直接 @% 3@（GF(3) 域内闭环）
-- > MixLayer2  不归约，留在层2（Z/3¹¹，值域 [0,24]）
-- > MixQ16     Q16 定点缩放后再 @% 3@（仲吕边界 2¹⁶）
-- > MixGF27    编码成 a+3b+9c 的 GF(27) 元素再乘（3 = α ≠ 0）
data MixMode = MixMod3 | MixLayer2 | MixQ16 | MixGF27
  deriving (Show, Eq)

--------------------------------------------------------------------------------
-- Christoffel 平行运输 + head 混合
--------------------------------------------------------------------------------

-- | 每个 head 的 6-trit tryte：@z3rMatmul@ 已归约，故无需 round/clamp。
christoffelInt
  :: MixMode      -- ^ head 混合方式
  -> Int          -- ^ heads
  -> [[Trit]]     -- ^ q_proj **权重**（GF(3) 元素）[heads*6 × dim]
  -> [[[Trit]]]   -- ^ prototype[head][to_cell]（权重）
  -> Int          -- ^ from_cell
  -> Int          -- ^ to_cell
  -> [Trit]       -- ^ x（trit 激活）
  -> [Int]
  -- ⚠️ 返回 @[Int]@ 而非 @[Trit]@：@MixLayer2@ 分支返回 [0,24]，范畴随
  -- 'MixMode' 而变。类型化只施加在范畴明确处，这个多态点保留宽类型并注明。
christoffelInt mode heads qW protos fromCell toCell x =
  concat [ mix transported (slice h x) | (h, transported) <- zip [0 ..] transportedAll ]
  where
    qTryte = z3rMatmul qW x
    shift  = gf3Shift fromCell (getDirection fromCell toCell)
    transportedAll =
      [ transportTryte (take 6 (drop (h * 6) qTryte)) (protos !! h !! toCell) shift
      | h <- [0 .. heads - 1] ]
    headDim = length x `div` heads
    slice h xs = take headDim (drop (h * headDim) xs)
    -- Σ trits 是层2 的整数累加（不归约）；按 mode 决定怎么塌回 GF(3)
    mix t xh = case mode of
      MixMod3   -> [ (sum (map tritToInt t) * tritToInt v) `mod` 3 | v <- xh ]
      MixLayer2 -> [ sum (map tritToInt t) * tritToInt v | v <- xh ]   -- 层2，值域 [0,24]
      MixQ16    -> [ (((sum (map tritToInt t) * fxpOne) `div` 6) * tritToInt v `div` fxpOne) `mod` 3 | v <- xh ]
      -- GF(27) 载体：Σtrits 编码成 a+3b+9c 的域元素，再与 v 做 GF(27) 乘。
      -- 3 = (0,1,0) = α 在 GF(27) 里非零（而 GF(3) 下 3≡0）。是否真能修好退化，
      -- 由实测决定 —— 因为下游 z3rMatmul 仍按 %3 归约，可能照样抹平。
      MixGF27   -> [ gf27Mul (gf27Encode (gf27Decode (sum (map tritToInt t)))) (tritToInt v) | v <- xh ]

--------------------------------------------------------------------------------
-- 层 / 前向
--------------------------------------------------------------------------------

-- | 本源层体：残差、归一化、FFN 全部在 GF(3) 上闭环。
layerIntrinsic
  :: MixMode -> SovereignConfig -> SovereignIntLayer -> DuodecPoint -> [Trit] -> [Trit]
layerIntrinsic mode cfg lyr st x = x2
  where
    heads  = scHeads cfg
    dim    = scDim cfg
    (cell, target) = snd (layerStep st)
    lut    = rsqrtLutQ16 dim (scEps cfg)
    gamma  = replicate dim (mkTrit 1)
    transported = z3rMatmul (silOutProj lyr)
                    (map mkTrit
                      (christoffelInt mode heads (silQProj lyr) (silPrototype lyr) cell target x))
    x1 = z3rRmsNorm lut gamma (zipWith tritAdd x transported)
    ffnOut = z3rSwiGLU (silGateProj lyr) (silUpProj lyr) (silDownProj lyr) x1
    x2 = z3rRmsNorm lut gamma (zipWith tritAdd x1 ffnOut)

-- | GF(3) 域上的嵌入：token_embed（本身就是 trit 权重）。
embedIntrinsic :: SovereignConfig -> SovereignIntWeights -> [Int] -> [[Trit]]
embedIntrinsic cfg w tokenIds =
  [ map mkTrit (take dim (rowToInts ++ repeat 0))
  | tok <- tokenIds
  , let rowToInts = map gf27ToInt (siwTokenEmbed w !! (tok `mod` length (siwTokenEmbed w))) ]
  where dim = scDim cfg

-- | 层推进经过的相位状态序列（共 @depth@ 个）。
phaseStates :: SovereignConfig -> [DuodecPoint]
phaseStates cfg = take (scDepth cfg) (iterate (\s -> fst (layerStep s)) (0, A0))

-- | 端到端：embedding → depth 层 → content bypass → final norm → lm_head。
-- 所有输出元素 ∈ {0,1,2}。
forwardIntrinsic :: MixMode -> SovereignConfig -> SovereignIntWeights -> [Int] -> [[Trit]]
forwardIntrinsic mode cfg w tokenIds = map headLogits normed
  where
    dim  = scDim cfg
    lut  = rsqrtLutQ16 dim (scEps cfg)
    gamma = replicate dim (mkTrit 1)
    embedded = embedIntrinsic cfg w tokenIds
    hidden = foldl (\hs (i, st) -> map (layerIntrinsic mode cfg (siwLayers w !! i) st) hs)
                   embedded (zip [0 ..] (phaseStates cfg))
    bypassed = [ zipWith tritAdd h (rowOf (siwContentBypass w) t)
               | (h, t) <- zip hidden tokenIds ]
    normed = map (z3rRmsNorm lut gamma) bypassed
    headLogits = z3rMatmul (siwLmHead w)
    rowOf table tok = take dim (table !! (tok `mod` length table) ++ repeat (mkTrit 0))

-- | 逐层状态轨迹：@depth + 1@ 帧（含初始帧），用于周期检测。
traceStates :: MixMode -> SovereignConfig -> SovereignIntWeights -> [Int] -> [[[Trit]]]
traceStates mode cfg w tokenIds =
  scanl (\hs (i, st) -> map (layerIntrinsic mode cfg (siwLayers w !! i) st) hs)
        (embedIntrinsic cfg w tokenIds)
        (zip [0 ..] (phaseStates cfg))
