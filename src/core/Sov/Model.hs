{-# LANGUAGE OverloadedStrings #-}

-- | The pyBitNet sovereign model's forward pass, assembled from the parts.
--
-- References (all in @/data/trit/pyBitNet@):
--
-- > embedding   bitnet/gf3/gf3_s2_lattice.py:327-458   (S2CellEmbedding + 球谐)
-- > layer       bitnet/gf3/gf3_s2_lattice.py:952-1007  (S2CellLayer)
-- > transport   bitnet/gf3/gf3_s2_lattice.py:563-630   (Christoffel, see Christoffel.hs)
-- > ffn / norm  bitnet/gf3/gf3_swiglu.py:21 / gf3_rmsnorm.py:23 (see GF3Ops.hs)
-- > model       bitnet/sovereign/sovereign_model.py:539 (S2Sovereign) / :292 (NayinDecoder)
-- > cells       bitnet/sovereign/sovereign_model.py:600-615 — a token's cell is
-- >             @token_id % 60@ (hence @% 12@ here), not its position
--
-- ⚠️ Components the checkpoint does **not** persist — @cell_embed@,
-- @phase_embed@, @toroidal_embed@, @prototype_matrix@, each @gamma@ and each
-- @scale@ — are random initialisations in the reference.  Here they take
-- deterministic values (zeros / 'defaultMonopolePrototype' / ones) so the two
-- sides can be compared value by value.
module Sov.Model
  ( SovereignConfig(..)
  , SovereignLayer(..)
  , SovereignWeights(..)
  , defaultMonopolePrototype
  , cellCenters
  , sphericalHarmonicExpand
  , s2CellEmbedding
  , layerForward
  , layerForwardAt
  , layerStep
  , layerForwardMixed
  , sovereignForward
  , sovereignForwardMixed
  ) where

import Sov.Christoffel (christoffelForward)
import Sov.GF3Ops (gf3RmsNorm, gf3RmsNormLut, gf3SwiGLU, ternaryLinear)
import Sov.GF3Intrinsic (AlphaPower(..), DuodecPoint, mixedOp, crt12)
import Sov.S2Geometry (icoVertices, r2Fxp, s2NumCells)

data SovereignConfig = SovereignConfig
  { scDim   :: Int      -- ^ 24n (1440 in the real model)
  , scDepth :: Int      -- ^ 60, locked by 京房六十律
  , scHeads :: Int      -- ^ 12, locked
  , scVocab :: Int      -- ^ 1536 in the real model
  , scFF    :: Int      -- ^ 3 × dim (ff_mult = 3, locked)
  , scEps   :: Double   -- ^ 1e-5
  } deriving (Show, Eq)

-- | One layer's weights.  The @*Scale@ vectors are the reference's per-channel
-- @scale@ parameters (default 1).
data SovereignLayer = SovereignLayer
  { slQProj     :: [[Double]], slQScale    :: [Double]
  , slOutProj   :: [[Double]], slOutScale  :: [Double]
  , slGateProj  :: [[Double]], slGateScale :: [Double]
  , slUpProj    :: [[Double]], slUpScale   :: [Double]
  , slDownProj  :: [[Double]], slDownScale :: [Double]
  , slPrototype :: [[[Int]]]                 -- ^ [heads][cells][6] (phase 0, as _fallback_monopole writes it)
  } deriving (Show, Eq)

data SovereignWeights = SovereignWeights
  { swTokenEmbed    :: [[Double]]   -- ^ [vocab][dim]
  , swContentBypass :: [[Double]]   -- ^ [vocab][dim]
  , swLmHead        :: [[Double]]   -- ^ [vocab][dim]
  , swLayers        :: [SovereignLayer]
  } deriving (Show, Eq)

--------------------------------------------------------------------------------
-- Deterministic stand-ins for the unpersisted parameters
--------------------------------------------------------------------------------

-- | The @C = −2@ monopole prototype of @_fallback_monopole@
-- (sovereign_model_trit.py:500-522): cells 2,3,6,7,10,11 are all-zero; cells
-- 0,1 / 4,5 / 8,9 carry a fixed six-trit pattern, written at phase 0.
defaultMonopolePrototype :: Int -> [[[Int]]]
defaultMonopolePrototype heads = replicate heads [ cellPattern cell | cell <- [0 .. s2NumCells - 1] ]
  where
    cellPattern cell
      | cell `elem` [2, 3, 6, 7, 10, 11] = [0, 0, 0, 0, 0, 0]
      | cell `elem` [0, 1]               = [0, 1, 2, 1, 2, 0]
      | cell `elem` [4, 5]               = [1, 2, 0, 2, 0, 1]
      | otherwise                        = [2, 0, 1, 0, 1, 2]   -- cells 8, 9

-- | Cell centres on the unit sphere (gf3_s2_lattice.py:115-117): the fixed-point
-- vertices divided by their common norm.
cellCenters :: [(Double, Double, Double)]
cellCenters =
  [ ( fromIntegral a / n, fromIntegral b / n, fromIntegral c / n )
  | (a, b, c) <- icoVertices ]
  where n = sqrt (fromIntegral r2Fxp)

--------------------------------------------------------------------------------
-- Embedding
--------------------------------------------------------------------------------

-- | @_spherical_harmonic_expand@ (gf3_s2_lattice.py:364-404): the nine real
-- spherical harmonics @Y_00 … Y_22@ of a unit vector, normalised by the largest
-- magnitude among them, then each discretised into three GF(3) states
-- (@< −0.1@, @∈[−0.1, 0.1]@, @> 0.1@) → 27 values.
sphericalHarmonicExpand :: (Double, Double, Double) -> [Double]
sphericalHarmonicExpand (x0, y0, z0) = concat [ [neg v, zero v, pos v] | v <- raw ]
  where
    r = sqrt (x0 * x0 + y0 * y0 + z0 * z0)
    d = if r < 1e-8 then 1 else r
    x = x0 / d ; y = y0 / d ; z = z0 / d
    c1 = sqrt (3 / (4 * pi))
    c2 = 0.25 * sqrt (15 / pi)
    raw =
      [ 0.5 / sqrt pi                                    -- Y_00
      , c1 * y, c1 * z, c1 * x                           -- Y_1-1, Y_10, Y_11
      , c2 * x * y, c2 * y * z                           -- Y_2-2, Y_2-1
      , 0.25 * sqrt (5 / pi) * (3 * z * z - 1)           -- Y_20
      , c2 * x * z                                       -- Y_21
      , 0.25 * sqrt (15 / pi) * (x * x - y * y) ]        -- Y_22
    biggest = maximum (map abs raw)
    norm v = v / (biggest + 1e-8)
    neg v  = if norm v < (-0.1) then 1 else 0
    zero v = let h = norm v in if h >= (-0.1) && h <= 0.1 then 1 else 0
    pos v  = if norm v > 0.1 then 1 else 0

-- | The embedding the checkpoint supports: @token_embed@ (persisted) plus the
-- spherical-harmonic code of the token's own cell.  The three learned tables
-- that are *not* persisted contribute zero.
s2CellEmbedding :: SovereignConfig -> [[Double]] -> [Int] -> [[Double]]
s2CellEmbedding cfg tokenEmbed tokenIds =
  [ zipWith (+) (tokenRow tok) (shRow tok) | tok <- tokenIds ]
  where
    dim = scDim cfg
    tokenRow tok = take dim (tokenEmbed !! (tok `mod` length tokenEmbed) ++ repeat 0)
    shRow tok =
      let c = cellCenters !! (tok `mod` s2NumCells)
      in take dim (sphericalHarmonicExpand c ++ repeat 0)

--------------------------------------------------------------------------------
-- Layer / model
--------------------------------------------------------------------------------

-- | The layer body with its @(cell, target)@ pair supplied explicitly, so the
-- advancement rule can be swapped without touching the arithmetic.
layerForwardAt :: SovereignConfig -> SovereignLayer -> (Int, Int) -> [Double] -> [Double]
layerForwardAt cfg lyr (cell, target) x = x2
  where
    heads  = scHeads cfg
    dim    = scDim cfg
    lut    = gf3RmsNormLut dim (scEps cfg)
    ones   = replicate dim 1
    -- transport, then out_proj (the reference applies out_proj inside the
    -- connection module; kept separate here so the parts stay testable)
    transported = ternaryLinear (slOutProj lyr) (slOutScale lyr)
                    (christoffelForward heads
                      (slQProj lyr) (slQScale lyr)
                      [ slPrototype lyr !! h !! target | h <- [0 .. heads - 1] ]
                      cell target x)
    x1 = gf3RmsNorm lut ones (zipWith (+) x transported)
    ffnOut = gf3SwiGLU
               (\v -> ternaryLinear (slGateProj lyr) (slGateScale lyr) v)
               (\v -> ternaryLinear (slUpProj lyr) (slUpScale lyr) v)
               (\v -> ternaryLinear (slDownProj lyr) (slDownScale lyr) v)
               x1
    x2 = gf3RmsNorm lut ones (zipWith (+) x1 ffnOut)

-- | The arithmetic-only view of a layer, advanced by the C₁₂ __projection__
-- @(layer_idx % 12, (layer_idx+1) % 12)@ — i.e. what the Python reference does.
-- Kept for compatibility; see 'layerForwardMixed' for the 本源 rule.
layerForward :: SovereignConfig -> SovereignLayer -> Int -> [Double] -> [Double]
layerForward cfg lyr layerIdx =
  layerForwardAt cfg lyr (layerIdx `mod` s2NumCells, (layerIdx + 1) `mod` s2NumCells)

--------------------------------------------------------------------------------
-- 本源相位推进: DuodecClock 的加乘联合周期
--
-- cell/target 不再来自 @layer_idx % 12@（C₁₂ 加法投影），而来自
-- @mixedOp@（Trit 分量走 ⊕、⟨α⟩ 分量走 mulAlpha）。本源 12 = lcm(char 3, ord α).
--------------------------------------------------------------------------------

-- | 推进一层：返回下一状态与这一层的 @(cell, target)@。
layerStep :: DuodecPoint -> (DuodecPoint, (Int, Int))
layerStep st = (nxt, (crt12 st, crt12 nxt))
  where nxt = mixedOp st (1, A1)      -- ⊕ 步进 T₁, ⟨α⟩ 旋转 A1

-- | 本源的层体：cell/target 由 @mixedOp@ 决定。
layerForwardMixed :: SovereignConfig -> SovereignLayer -> DuodecPoint -> [Double] -> [Double]
layerForwardMixed cfg lyr st = layerForwardAt cfg lyr (snd (layerStep st))

-- | The whole model: embedding → @depth@ layers → content bypass → final norm →
-- lm_head.  Returns one logits vector per token.
sovereignForward :: SovereignConfig -> SovereignWeights -> [Int] -> [[Double]]
sovereignForward cfg w tokenIds = map headLogits normed
  where
    dim  = scDim cfg
    ones = replicate dim 1
    lut  = gf3RmsNormLut dim (scEps cfg)
    embedded = s2CellEmbedding cfg (swTokenEmbed w) tokenIds
    hidden   = foldl (\xs i -> map (layerForward cfg (swLayers w !! i) i) xs)
                     embedded [0 .. scDepth cfg - 1]
    bypassed = [ zipWith (+) h (tableRow (swContentBypass w) t)
               | (h, t) <- zip hidden tokenIds ]
    normed   = map (gf3RmsNorm lut ones) bypassed
    headLogits v = ternaryLinear (swLmHead w) ones v
    tableRow table tok = take dim (table !! (tok `mod` length table) ++ repeat 0)

-- | 本源前向：层推进走 DuodecClock 的 @mixedOp@（加乘联合周期），而非 C₁₂ 投影。
-- 相位链 @(T₀,a0) →(T₁,a1)→ …@ 每 12 层回到单位元，故 @depth@ 为 12 的倍数时
-- 恰好走完整数个"呼吸"（60 层 = 5 个）。
sovereignForwardMixed :: SovereignConfig -> SovereignWeights -> [Int] -> [[Double]]
sovereignForwardMixed cfg w tokenIds = map headLogits normed
  where
    dim  = scDim cfg
    ones = replicate dim 1
    lut  = gf3RmsNormLut dim (scEps cfg)
    embedded = s2CellEmbedding cfg (swTokenEmbed w) tokenIds
    states   = take (scDepth cfg) (iterate (\st -> fst (layerStep st)) (0, A0))
    hidden   = foldl (\hs (i, st) -> map (layerForwardMixed cfg (swLayers w !! i) st) hs)
                     embedded (zip [0 ..] states)
    bypassed = [ zipWith (+) h (tableRow (swContentBypass w) t)
               | (h, t) <- zip hidden tokenIds ]
    normed   = map (gf3RmsNorm lut ones) bypassed
    headLogits v = ternaryLinear (swLmHead w) ones v
    tableRow table tok = take dim (table !! (tok `mod` length table) ++ repeat 0)
