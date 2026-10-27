{-# LANGUAGE OverloadedStrings #-}

-- | GF(3) operators of the pyBitNet sovereign model.
--
-- Transcribed from the reference implementations (line numbers per definition);
-- the maths is done in 'Double' for accuracy — the reference runs float32.
--
-- The one simplification worth stating: in GF(3) @x² ≡ (x ≠ 0)@, so a
-- normalisation's mean-square is the *integer* count of non-zero entries.  The
-- reference still routes it through @round(mean_sq * dim)@ (gf3_rmsnorm.py:57-61);
-- both agree exactly, and the integer form cannot drift.
module Sov.GF3Ops
  ( gf3RmsNormLut
  , gf3RmsNorm
  , gf3SqrtGate
  , gf3SwiGLU
  , ternaryLinear
  ) where

-- | The rsqrt lookup table (gf3_rmsnorm.py:45-53): index @i@ holds
-- @1 \/ sqrt(i\/dim + eps)@, so @lut[0] = 1\/sqrt(eps)@.
gf3RmsNormLut :: Int -> Double -> [Double]
gf3RmsNormLut dim eps =
  [ 1 / sqrt (fromIntegral i / fromIntegral dim + eps) | i <- [0 .. dim] ]

-- | GF(3) RMSNorm (gf3_rmsnorm.py:55-…): scale by the LUT entry selected by
-- the count of non-zero components, then by @gamma@ (all ones by default).
gf3RmsNorm :: [Double] -> [Double] -> [Double] -> [Double]
gf3RmsNorm lut gamma xs = zipWith (\x g -> x * r * g) xs gamma
  where
    nonzero = length (filter (/= 0) xs)
    r = lut !! min nonzero (length lut - 1)

-- | The @√3@ lattice gate (gf3_swiglu.py:41-53): a token passes only if
-- @‖g‖² > 1.0@ — "每个 token 必须跨越能隙 Δ=√3 才能激活输出".
gf3SqrtGate :: [Double] -> Double
gf3SqrtGate g = if sum [ x * x | x <- g ] > 1.0 then 1.0 else 0.0

-- | GF(3) SwiGLU (gf3_swiglu.py:55-…): @down(gate_gated * up)@ where the gate
-- arm is thresholded by 'gf3SqrtGate'.
gf3SwiGLU
  :: ([Double] -> [Double])   -- ^ gate_proj
  -> ([Double] -> [Double])   -- ^ up_proj
  -> ([Double] -> [Double])   -- ^ down_proj
  -> [Double] -> [Double]
gf3SwiGLU gateProj upProj downProj x =
  downProj (zipWith (*) (map (* gf3SqrtGate g) g) u)
  where
    g = gateProj x
    u = upProj x

-- | A TQT_0 linear layer (tqt0.py:226, :318): @y = scale ⊙ (W_trit @ x)@ with
-- ternary weights in @{0,1,2}@.  @scale@ is per output channel (default 1).
ternaryLinear :: [[Double]] -> [Double] -> [Double] -> [Double]
ternaryLinear w scale x = zipWith (\row s -> s * dot row x) w scale
  where
    dot row vec = sum (zipWith (*) row vec)
