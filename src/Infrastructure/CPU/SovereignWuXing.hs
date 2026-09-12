{-# LANGUAGE OverloadedStrings #-}

-- | 五行推理层的数学本底 —— **五正多面体对称群的模结构**，不是传统五行。
--
-- 参考 @Sovereign.Structology@（Agda，0 postulate）：
--
-- > Platonics.agda        五正多面体 → 五行基数
-- >                       （对称群特征模数经 CRT 投影到 Z_144×Z_46 后的最小非平凡代表）
-- > WuXingEulerHFM.agda   五正多面体 Euler 示性数 χ = V − E + F = 2（逐个 refl）
-- > WuXingTransition.agda 五行对称群跃迁链 A₄ → O_h → I_h → I → O → A₄；
-- >                       Christoffel 螺旋 1→2→4→8→7→5（×2 mod 9，周期 6）
-- >                         → 模 3 投影 [1,2,1,2,1,2] = 损益交替（1=Sun、2=Yi）
-- >                         → scanl 累加 [0,1,3,4,6] = a 序列 = 五行相位
-- >                         → a 的奇偶 → Z₂ 手性因子
-- > IhC60Vibration.agda   I_h（阶 120）作用于 C60 的 174 维振动表示
-- >                       → 恰好 46 个独立基频   ← 这就是 TOROIDAL = 46
--
-- 缠绕常数（@Structology/Winding.agda@）：POLAR = 144 = 120(I_h) + 24(手征正四面体)，
-- TOROIDAL = 46。pyBitNet 的 @WUXING_MODS = [4,8,6,2,5]@（金木水火土）与此一致。
module Infrastructure.CPU.SovereignWuXing
  ( wuXingMods
  , wuXingNames
  , platonicsOrders
  , christoffelSpiral
  , spiralMod3
  , aSequence
  , wuXingPhaseOf
  , chiralityZ2
  , nayin
  , polarWinding144
  , toroidalWinding46
  , c60IndependentFrequencies
  ) where

-- | 五行基数（金木水火土）—— @Platonics.agda@：五正多面体对称群特征模数经 CRT
-- 投影到 @Z_144 × Z_46@ 后，非平凡同余类的最小代表。
wuXingMods :: [Int]
wuXingMods = [4, 8, 6, 2, 5]

-- 顺序与 'aSequence' 的 a 值（0,1,3,4,6）一一对应 ——
-- WuXingTransition.agda 定义 Fire a=0、Earth a=1、Metal a=3、Water a=4、Wood a=6。
wuXingNames :: [String]
wuXingNames = ["火", "土", "金", "水", "木"]

-- | 五正多面体的对称群阶（@Platonics.agda@ / @WuXingTransition.agda@ 的跃迁链）。
platonicsOrders :: [(String, String, Int)]
platonicsOrders =
  [ ("火", "A4  (正四面体)", 12)
  , ("土", "O_h (正六面体)", 48)
  , ("金", "I_h (正十二面体)", 120)
  , ("水", "I   (正二十面体)", 60)
  , ("木", "O   (正八面体)", 24) ]

-- | Christoffel 螺旋：@×2 mod 9@，周期 6（@WuXingTransition.agda@ v5.6）。
christoffelSpiral :: [Int]
christoffelSpiral = [1, 2, 4, 8, 7, 5]

-- | 螺旋的模 3 投影 = 损益交替（1 = Sun 损一，2 = Yi 益一）。
spiralMod3 :: [Int]
spiralMod3 = [1, 2, 1, 2, 1, 2]

-- | @scanl (+) 0@ 累加，取前 5 项 = a 序列 @[0,1,3,4,6]@ = 五行相位
-- （@WuXingTransition.agda@ 的 @scanl 累加 [0,1,3,4,6]@）。
aSequence :: [Int]
aSequence = take 5 (scanl (+) 0 spiralMod3)

-- | 由 a 值回查五行相位。
wuXingPhaseOf :: Int -> Maybe String
wuXingPhaseOf a = lookup a (zip [0, 1, 3, 4, 6] wuXingNames)

-- | 手性 Z₂ 因子：a 奇数 → 含反射（Present），偶数 → 纯旋转（Absent）。
chiralityZ2 :: Int -> Bool
chiralityZ2 a = odd a

-- | 纳音：@(五行模数 × 极向相位) mod 60@（pyBitNet @dialect.py:86@）。
nayin :: Int -> Int -> Int
nayin d polar = (wuXingMods !! (d `mod` 5) * polar) `mod` 60

-- | 极向缠绕 @144 = I_h 阶 120 + 手征正四面体 24@（@Winding.agda@）。
polarWinding144 :: Int
polarWinding144 = 144

-- | 环向缠绕 @46@ = C60 振动表示在 @I_h@ 下的独立基频数（@IhC60Vibration.agda@）。
toroidalWinding46 :: Int
toroidalWinding46 = 46

-- | @IhC60Vibration.agda@ 的主定理给出的重数向量 @(2,1,3,4,4,5,6,6,8,7)@
-- 之和，即独立基频数 46。
c60IndependentFrequencies :: (Int, [Int])
c60IndependentFrequencies = (sum mults, mults)
  where mults = [2, 1, 3, 4, 4, 5, 6, 6, 8, 7]
