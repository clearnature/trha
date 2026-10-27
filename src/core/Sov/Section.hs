{-# LANGUAGE OverloadedStrings #-}

-- | 主权区段 —— 30 位三进制状态与主权 LCM 环。
--
-- 参考 @Sovereign.Coupling.LCM@（Agda，0 postulate）：
--
-- > SOVEREIGN_LCM = 11609505792                -- = 3¹¹ × 2¹⁶
-- > SovereignSection = Vec Trit 30             -- 30 位三进制状态
-- > powersOf3 = 1 ∷ 3 ∷ … ∷ 3²⁹                -- 30 项位权表
-- > sectionToCoordinate sec = eval-vec (map toℕ sec) powersOf3
-- > coordinateToSection n   = enc 30 n          -- 反复 mod 3 / div 3
-- > modLCM sec = coordinateToSection (sectionToCoordinate sec mod SOVEREIGN_LCM)
--
-- 参考 @Sovereign.Coupling.LossGain@：
--
-- > POW3¹¹ = 177147   POW2¹⁶ = 65536
-- > zhonglvAlign acc = (acc * POW3¹¹) / POW2¹⁶
--
-- 这是 M7 里 @crt12@（模 12 的加法投影）所缺的层级：真正的环是
-- @Z/(3¹¹·2¹⁶)Z@，由 CRT 分解为 @Z/3¹¹ × Z/2¹⁶@（@gcd(3¹¹,2¹⁶)=1@）。
module Sov.Section
  ( sovereignLCM
  , pow3_11
  , pow2_16
  , powersOf3
  , SovereignSection
  , sectionToCoordinate
  , coordinateToSection
  , modLCM
  , zhonglvAlign
  , zhonglvAlignMod
  ) where

-- | 主权 LCM 模数 @3¹¹ × 2¹⁶ = 11609505792@（= 黄钟 × 仲吕）。
sovereignLCM :: Integer
sovereignLCM = 11609505792

-- | @3¹¹ = 177147@（黄钟 / 仲吕对齐乘数）。
pow3_11 :: Integer
pow3_11 = 177147

-- | @2¹⁶ = 65536@（仲吕 / 仲吕对齐除数）。
pow2_16 :: Integer
pow2_16 = 65536

-- | 30 项位权表 @1, 3, 9, …, 3²⁹@，逐项对应 @LCM.agda@ 的 @powersOf3@。
powersOf3 :: [Integer]
powersOf3 = take 30 (iterate (* 3) 1)

-- | 状态 = 30 位三进制（每个分量 ∈ {0,1,2}）。
type SovereignSection = [Int]

-- | 位权展开（对应 @sectionToCoordinate@ / @eval-vec@）。
sectionToCoordinate :: SovereignSection -> Integer
sectionToCoordinate sec =
  sum [ fromIntegral t * p | (t, p) <- zip sec powersOf3 ]

-- | 逆运算（对应 @coordinateToSection@ 的 @enc 30@）：反复取 @mod 3@ 与 @div 3@。
coordinateToSection :: Integer -> SovereignSection
coordinateToSection n = take 30 (go (n `mod` sovereignLCM))
  where
    go 0 = repeat 0
    go m = fromIntegral (m `mod` 3) : go (m `div` 3)

-- | 环的载体：对 @3¹¹ × 2¹⁶@ 取模（对应 @modLCM@）。
modLCM :: SovereignSection -> SovereignSection
modLCM sec = coordinateToSection (sectionToCoordinate sec `mod` sovereignLCM)

--------------------------------------------------------------------------------
-- 桥（仲吕对齐）—— 见 Coupling/LossGain.agda
--------------------------------------------------------------------------------

-- | @zhonglvAlign acc = (acc * 3¹¹) / 2¹⁶@ —— 仲吕对齐，每 12 步损益后执行。
zhonglvAlign :: Integer -> Integer
zhonglvAlign acc = (acc * pow3_11) `div` pow2_16

-- | 桥的模运算版本 @(n * 3¹¹) % 2¹⁶@（对应 @zhonglvAlignMod@）。
zhonglvAlignMod :: Integer -> Integer
zhonglvAlignMod n = (n * pow3_11) `mod` pow2_16
