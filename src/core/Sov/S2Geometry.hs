{-# LANGUAGE OverloadedStrings #-}

-- | S² cell geometry of the pyBitNet sovereign model — the static tables.
--
-- The adjacency / orbit / Christoffel tables are transcribed verbatim from
-- @bitnet/sovereign/sovereign_model_trit.py:71-143@ (whose own comment says it
-- matches @gf3_s2_lattice.py@).  The geodesic distances are **computed** from
-- the fixed-point icosahedron of @gf3_s2_lattice.py:80-159@ instead of copied
-- as numbers, so we stay on the reference's own path.
--
-- Two facts that simplify everything downstream:
--
--   * @christoffel_gf3@ is @[1,2,0]@ on *every* row (clockwise→+1,
--     counter-clockwise→+2, MuGong→0) — the shift depends only on the direction.
--   * a direction is the neighbour index; for non-adjacent cells it falls back
--     to @floor(geodesic) mod 3@ (gf3_s2_lattice.py:553-561).  The geodesic
--     values are 1.107…, 2.034… and π radians, so that fallback ranges over
--     {0,1,2} — it is **not** always zero.
module Sov.S2Geometry
  ( s2NumCells
  , s2Neighbors
  , s2C3Orbits
  , toneNames
  , cellAdjacency
  , c3Orbits
  , christoffelGf3
  , gf3Mul
  , getDirection
  , gf3Shift
  , tryteNonzero
  , fxpQ
  , fxpPhi
  , icoVertices
  , r2Fxp
  , cellGeodesic
  , adjLookupTable
  ) where

import Data.Text (Text)

-- | Twelve S² cells (京房十二律).
s2NumCells :: Int
s2NumCells = 12

-- | Each cell has three neighbours.
s2Neighbors :: Int
s2Neighbors = 3

-- | Four C3 orbits.
s2C3Orbits :: Int
s2C3Orbits = 4

toneNames :: [Text]
toneNames =
  [ "黄钟", "林钟", "太簇", "南吕"
  , "姑洗", "应钟", "蕤宾", "大吕"
  , "夷则", "夹钟", "无射", "仲吕" ]

cellAdjacency :: [[Int]]
cellAdjacency =
  [ [4, 8, 3], [5, 9, 4], [6, 10, 5], [7, 11, 6]
  , [8, 0, 7], [9, 1, 8], [10, 2, 9], [11, 3, 10]
  , [0, 4, 11], [1, 5, 0], [2, 6, 1], [3, 7, 2] ]

c3Orbits :: [[Int]]
c3Orbits =
  [ [0, 4, 8], [1, 5, 9], [2, 6, 10], [3, 7, 11] ]

-- | Christoffel GF(3) signs — every row is @[1,2,0]@.
christoffelGf3 :: [[Int]]
christoffelGf3 = replicate s2NumCells [1, 2, 0]

-- | GF(3) multiplication table.
gf3Mul :: [[Int]]
gf3Mul =
  [ [0, 0, 0]
  , [0, 1, 2]
  , [0, 2, 1] ]

--------------------------------------------------------------------------------
-- Fixed-point icosahedron (gf3_s2_lattice.py:80-159)
--------------------------------------------------------------------------------

-- | @FXP_Q@ — the Q16.16 scale.
fxpQ :: Integer
fxpQ = 65536

-- | @⌊Q · F20\/F19⌉@ with φ ≈ 6765/4181 (gf3_s2_lattice.py:94-96).
fxpPhi :: Integer
fxpPhi = (fxpQ * 6765 + 4181 `div` 2) `div` 4181

-- | The twelve icosahedron vertices in the reference's order — that order is
-- what gives @cellAdjacency@ its meaning.
icoVertices :: [(Integer, Integer, Integer)]
icoVertices =
  [ (0, fxpQ, fxpPhi), (0, -fxpQ, fxpPhi), (0, fxpQ, -fxpPhi), (0, -fxpQ, -fxpPhi)
  , (fxpQ, fxpPhi, 0), (-fxpQ, fxpPhi, 0), (fxpQ, -fxpPhi, 0), (-fxpQ, -fxpPhi, 0)
  , (fxpPhi, 0, fxpQ), (-fxpPhi, 0, fxpQ), (fxpPhi, 0, -fxpQ), (-fxpPhi, 0, -fxpQ) ]

-- | @R² = ONE² + PHI²@ (gf3_s2_lattice.py:104).
r2Fxp :: Integer
r2Fxp = fxpQ * fxpQ + fxpPhi * fxpPhi

-- | Squared distance between two vertices (unnormalised, as stored).
sqDistFxp :: Int -> Int -> Integer
sqDistFxp i j =
  let (a1, b1, c1) = icoVertices !! (i `mod` s2NumCells)
      (a2, b2, c2) = icoVertices !! (j `mod` s2NumCells)
  in (a1 - a2) * (a1 - a2) + (b1 - b2) * (b1 - b2) + (c1 - c2) * (c1 - c2)

-- | Spherical distance in radians: @acos(1 − d²\/(2R²))@
-- (gf3_s2_lattice.py:157-159).
cellGeodesic :: Int -> Int -> Double
cellGeodesic i j =
  acos (1 - fromIntegral (sqDistFxp i j) / (2 * fromIntegral r2Fxp))

-- | @0@ = C3cw, @1@ = C3ccw, @2@ = MuGong.  Adjacent cells answer by neighbour
-- index; otherwise the geodesic decides — exactly as the reference does.
getDirection :: Int -> Int -> Int
getDirection fromCell toCell =
  case [ d | (d, n) <- zip [0 ..] (cellAdjacency !! (fromCell `mod` s2NumCells))
           , n == toCell `mod` s2NumCells ] of
    (d : _) -> d
    []      -> floor (cellGeodesic fromCell toCell) `mod` 3

-- | @christoffel_gf3[cell][direction]@ — the parallel-transport shift.
gf3Shift :: Int -> Int -> Int
gf3Shift cell direction = (christoffelGf3 !! (cell `mod` s2NumCells)) !! (direction `mod` 3)

-- | The reference's precomputed @_adj_lookup@ buffer
-- (gf3_s2_lattice.py:504-511), derived here by the same rule.
adjLookupTable :: [[Int]]
adjLookupTable =
  [ [ getDirection f t | t <- [0 .. s2NumCells - 1] ] | f <- [0 .. s2NumCells - 1] ]

-- | How many of a 6-trit tryte are non-zero.
tryteNonzero :: [Int] -> Int
tryteNonzero = length . filter (/= 0)
