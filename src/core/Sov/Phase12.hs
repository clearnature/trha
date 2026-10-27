{-# LANGUAGE OverloadedStrings #-}

-- | 十二律相位机 —— 用真实十二律相位驱动层推进（替代 M7g 的 @% 12@ 投影），
-- 并提供 @Z12Sys ↔ HoloState@ 的坐标级互映。
--
-- 三方依据：
--
-- > Sovereign.Coupling.LossGain   损 ×2/3、益 ×4/3；损 (a+1,b-1)、益 (a+2,b-1)
-- > Sovereign.Coupling.Zhonglv    acc ↦ (acc × 177147) >> 16，**每 12 步损益后执行**
-- > bitnet/gf3/holographic_sunyi  S=(a,b,c,d)：b 为十二律相位(mod 144)，b%12 给律名
--
-- 与 M7g 的区别：M7g 用 @DuodecClock@ 的 @mixedOp@ 走 @crt12@（模 12 的加法投影）；
-- 这里换成 @Zhonglv@ 的时序 —— **损-益交替，每 12 步应用桥（仲吕对齐）**，
-- 而 @cell/target@ 取自 @b % 12@（真实十二律，不是抽象计数器）。
module Sov.Phase12
  ( Phase12(..)
  , phase12Init
  , step12
  , phaseSeq12
  , layerStep12
  , cellTrajectory12
  , z12FromHolo
  , holoFromZ12
  , breatheCount
  ) where

import Sov.LossGain (HoloState(..), holoGain, holoLoss)
import Sov.Section (zhonglvAlign)
import Sov.Z12Sys (Q(..), Z12(..), qnum)

-- | 十二律相位机：相位 @HoloState@ + 累加器（整数坐标）+ 步数。
data Phase12 = Phase12
  { p12Holo :: HoloState  -- ^ 4D 相位 (a,b,c,d)
  , p12Acc  :: Integer    -- ^ 累加器（桥作用的对象）
  , p12Step :: Int        -- ^ 已走步数
  } deriving (Show, Eq)

-- | 初值：黄钟 @(a,b,c,d) = (0,0,0,5)@，累加器取黄钟余数 @3¹¹@。
phase12Init :: Phase12
phase12Init = Phase12 (HoloState 0 0 0 5) 177147 0

-- | 一步：损-益交替（@LossGain@）；**每 12 步**应用桥（@Zhonglv@ 的呼吸）。
step12 :: Phase12 -> Phase12
step12 (Phase12 h acc i) =
  Phase12 h' acc' (i + 1)
  where
    h' = if even i then holoLoss h else holoGain h
    acc' = if (i + 1) `mod` 12 == 0 then zhonglvAlign acc else acc

-- | 相位序列（前 n 步，含初值）。
phaseSeq12 :: Int -> [Phase12]
phaseSeq12 n = take n (iterate step12 phase12Init)

-- | 层推进（真实十二律版）：返回下一相位与该层的 @(cell, target)@。
-- @cell = b % 12@（当前律），@target = b' % 12@（下一律）。
layerStep12 :: Phase12 -> (Phase12, (Int, Int))
layerStep12 p = (p', (cell, target))
  where
    p' = step12 p
    cell = hsB (p12Holo p) `mod` 12
    target = hsB (p12Holo p') `mod` 12

-- | 层推进的 cell 轨迹。
cellTrajectory12 :: Int -> [Int]
cellTrajectory12 n =
  [ cell | (_, (cell, _)) <- map layerStep12 (take n (iterate step12 phase12Init)) ]

-- | 走过的完整呼吸次数（每 12 步一次桥）。
breatheCount :: Phase12 -> Int
breatheCount = (`div` 12) . p12Step

--------------------------------------------------------------------------------
-- E4: Z12Sys ↔ HoloState 的坐标级互映
--------------------------------------------------------------------------------

-- | 把 4D 相位按坐标嵌入 @Z12Sys@ 的四个 ℚ 分量（整数 → 有理数）。
-- 注意这是__坐标级__嵌入：@HoloState@ 各分量带 @mod 144/46/5@，而 @Z12Sys@ 是域，
-- 二者维数相同（都是 4）但不是同构。
z12FromHolo :: HoloState -> Z12
z12FromHolo (HoloState a b c d) =
  Z12 (qnum (toInteger a) 1) (qnum (toInteger b) 1) (qnum (toInteger c) 1) (qnum (toInteger d) 1)

-- | 反向：仅当四个分量都是整数时成功（即落在嵌入的像里）。
holoFromZ12 :: Z12 -> Maybe HoloState
holoFromZ12 (Z12 a b c d) = do
  a' <- intOf a
  b' <- intOf b
  c' <- intOf c
  d' <- intOf d
  pure (HoloState a' b' c' d')
  where
    intOf (Q n 1) = Just (fromInteger n)
    intOf _       = Nothing
