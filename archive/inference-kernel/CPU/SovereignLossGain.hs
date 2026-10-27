{-# LANGUAGE OverloadedStrings #-}

-- | 损益算子与十二律长度链。
--
-- 参考 @Sovereign.Coupling.LossGain@（Agda）：
--
-- > data LossGain : Set where
-- >   Sun : LossGain   -- 损一（长度 × 2/3）
-- >   Yi  : LossGain   -- 益一（长度 × 4/3）
-- > sunOp n = (n * 2) / 3        -- 整除版
-- > yiOp  n = (n * 4) / 3
-- > -- 注释：损 (a+1, b-1)、益 (a+2, b-1)   ← 与 pyBitNet HolographicState 一致
--
-- 参考 @Sovereign.Coupling.Zhonglv@ 的 @lengToNat@（硬编码的十二律长度表）：
--
-- > 黄钟 81 → 林钟 54 → 太簇 72 → 南吕 48 → 姑洗 64 → 应钟 43
-- > → 蕤宾 57 → 大吕 38 → 夷则 51 → 夹钟 34 → 无射 45 → 仲吕 30
--
-- ⚠️ 两处口径不同（实测得出，不掩盖）：
--   LossGain 用整除：(64 × 2) / 3 = 42
--   Zhonglv 的表是    ：64 × 2/3 = 42.67 → 43（四舍五入）
-- 因此两种都实现，并以 Zhonglv 的 12 项表作为 round 版的判据。
module Infrastructure.CPU.SovereignLossGain
  ( sunOpDiv
  , yiOpDiv
  , sunOpRound
  , yiOpRound
  , lengSequenceDiv
  , lengSequenceRound
  , tones
  , lossGainTones
  , toneOf
  , HoloState(..)
  , holoLoss
  , holoGain
  , holoCycle
  , polarWinding
  , toroidalWinding
  ) where

--------------------------------------------------------------------------------
-- 损益算子
--------------------------------------------------------------------------------

-- | 损一：@n * 2 / 3@（整除，照 @LossGain.sunOp@）。
sunOpDiv :: Integral a => a -> a
sunOpDiv n = (n * 2) `div` 3

-- | 益一：@n * 4 / 3@（整除，照 @LossGain.yiOp@）。
yiOpDiv :: Integral a => a -> a
yiOpDiv n = (n * 4) `div` 3

-- | 损一的四舍五入版（匹配 @Zhonglv.lengToNat@ 的表）。
sunOpRound :: Integral a => a -> a
sunOpRound n = (n * 2 + 1) `div` 3

-- | 益一的四舍五入版。
yiOpRound :: Integral a => a -> a
yiOpRound n = (n * 4 + 1) `div` 3

-- | 从黄钟 81 出发，损-益交替 11 步（整除版，照 @LossGain@ 的算子）。
lengSequenceDiv :: [Integer]
lengSequenceDiv = scanl apply 81 [0 .. 10]
  where apply n i = if even i then sunOpDiv n else yiOpDiv n

-- | 从黄钟 81 出发，损-益交替 11 步（四舍五入版，照 @Zhonglv@ 的表）。
lengSequenceRound :: [Integer]
lengSequenceRound = scanl apply 81 [0 .. 10]
  where apply n i = if even i then sunOpRound n else yiOpRound n

-- | 十二律名，__半音次序__ —— pyBitNet @holographic_sunyi.py@ 的 @TONE_NAMES@。
-- 这是 @HolographicState.b % 12@ 使用的次序。
tones :: [String]
tones =
  [ "黄钟", "大吕", "太簇", "夹钟", "姑洗", "仲吕"
  , "蕤宾", "林钟", "夷则", "南吕", "无射", "应钟" ]

-- | 十二律名，__损益次序__ —— @Sovereign.Coupling.Zhonglv@ 的 @LuName@ 声明次序。
-- （与上面不同：这里第 2 位是林钟，不是大吕。）
lossGainTones :: [String]
lossGainTones =
  [ "黄钟", "林钟", "太簇", "南吕", "姑洗", "应钟"
  , "蕤宾", "大吕", "夷则", "夹钟", "无射", "仲吕" ]

-- | 第 i 律之名（@b % 12@ 形式，半音次序）。
toneOf :: Int -> String
toneOf b = tones !! (b `mod` 12)

--------------------------------------------------------------------------------
-- 4D 全息状态（pyBitNet bitnet/gf3/holographic_sunyi.py 的 HolographicState）
--------------------------------------------------------------------------------

-- | @S = (a, b, c, d)@：a 黄钟倍频指数、b 极向相位(mod 144)、c 环向偏移(mod 46)、d 五行模数(mod 5)。
data HoloState = HoloState
  { hsA :: Int   -- ^ 分子 2 的指数（损 +1、益 +2）
  , hsB :: Int   -- ^ 十二律相位（每步 −1，mod 144）
  , hsC :: Int   -- ^ 环向偏移（损 +1、益 +2，mod 46）
  , hsD :: Int   -- ^ 五行模数（损 +1、益 +4，mod 5）
  } deriving (Show, Eq)

-- | 损（相克）：@a+=1, b-=1, c+=1, d=(d+1)%5@。
holoLoss :: HoloState -> HoloState
holoLoss (HoloState a b c d) =
  HoloState (a + 1) ((b - 1) `mod` polarWinding) (c + 1) ((d + 1) `mod` 5)

-- | 益（相生）：@a+=2, b-=1, c+=2, d=(d+4)%5@。
holoGain :: HoloState -> HoloState
holoGain (HoloState a b c d) =
  HoloState (a + 2) ((b - 1) `mod` polarWinding) (c + 2) ((d + 4) `mod` 5)

-- | 损-益交替 11 步（从黄钟 @(0,0,0,5)@ 出发）。
holoCycle :: [HoloState]
holoCycle = scanl apply (HoloState 0 0 0 5) [0 .. 10]
  where apply s i = if even i then holoLoss s else holoGain s

-- | 极向缠绕 @144 = 120 + 24@（pyBitNet POLAR）。
polarWinding :: Int
polarWinding = 144

-- | 环向缠绕 46（pyBitNet TOROIDAL）。
toroidalWinding :: Int
toroidalWinding = 46
