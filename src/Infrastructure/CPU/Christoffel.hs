{-# LANGUAGE OverloadedStrings #-}

-- | Christoffel parallel transport — pyBitNet's replacement for attention.
--
-- Transcribed from @bitnet/gf3/gf3_s2_lattice.py@: transport at :517-551,
-- the forward pass at :563-630.  A token does not "attend" to other tokens; it
-- is **parallel-transported** from its cell to the next one along the C3 orbit,
-- and what moves is a 6-trit tryte in GF(3).
--
-- The five reference steps, kept in the same order and naming:
--
-- > proto        = prototype[head, to_cell, 0]        -- target cell, phase 0
-- > delta        = (q − proto) mod 3
-- > rot          = (delta + christoffel_gf3[from][direction]) mod 3
-- > transported  = (rot * chiral_gate[rot]) mod 3     -- gate = [0,1,2] ⇒ rot
-- > trit_sum     = Σ transported / 6.0
-- > mixed        = trit_sum × x_heads                 -- then out_proj
--
-- @chiral_gate = [0,1,2]@ makes step 4 the identity, but it is written out so
-- the code still says what the model says.
module Infrastructure.CPU.Christoffel
  ( transportTryte
  , chiralGate
  , tryteOf
  , christoffelMix
  , christoffelForward
  ) where

import Infrastructure.CPU.SovereignTypes (Trit, mkTrit, tritToInt)
import Infrastructure.CPU.GF3Ops (ternaryLinear)
import Infrastructure.CPU.S2Geometry (getDirection, gf3Shift)

-- | @chiral_gate@ — the GF(3) multiplication gate (gf3_s2_lattice.py:500).
chiralGate :: [Int]
chiralGate = [0, 1, 2]

-- | Quantise a projected value into a trit: @round → clamp(0,2)@
-- (gf3_s2_lattice.py:589).
tryteOf :: [Double] -> [Int]
tryteOf = map (clamp3 . round)
  where clamp3 n = max 0 (min 2 n)

-- | The core transport of one 6-trit tryte (gf3_s2_lattice.py:517-551).
transportTryte :: [Trit] -> [Trit] -> Int -> [Trit]
transportTryte qTryte protoTryte shift =
  [ mkTrit (r * (chiralGate !! (r `mod` 3))) | r <- rotated ]
  where
    delta   = zipWith (\q p -> (tritToInt q - tritToInt p) `mod` 3) qTryte protoTryte
    rotated = [ (d + shift) `mod` 3 | d <- delta ]

-- | One head's contribution: the tryte collapses to @Σ trits / 6.0@ and scales
-- that head's slice of the input (gf3_s2_lattice.py:611-617).
christoffelMix :: [Int] -> [Double] -> [Double]
christoffelMix transported xHead =
  map (* (fromIntegral (sum transported) / 6.0)) xHead

-- | The full Christoffel forward for one token, returning @multi_head@ — the
-- caller applies @out_proj@ (gf3_s2_lattice.py:563-630).
christoffelForward
  :: Int            -- ^ number of heads
  -> [[Double]]     -- ^ q_proj weights, [heads*6 × dim]
  -> [Double]       -- ^ q_proj scale
  -> [[Int]]        -- ^ prototype[head, to_cell, 0] → [heads][6]
  -> Int            -- ^ from_cell
  -> Int            -- ^ to_cell
  -> [Double]       -- ^ x, [dim]
  -> [Double]
christoffelForward heads qW qS protos fromCell toCell x =
  concat [ christoffelMix transported (slice h x) | (h, transported) <- zip [0 ..] transportedAll ]
  where
    qTryte = tryteOf (ternaryLinear qW qS x)                 -- [heads*6]
    shift  = gf3Shift fromCell (getDirection fromCell toCell)
    transportedAll =
      [ transportTryte (take 6 (drop (h * 6) qTryte)) (protos !! h) shift
      | h <- [0 .. heads - 1] ]
    headDim = length x `div` heads
    slice h xs = take headDim (drop (h * headDim) xs)
