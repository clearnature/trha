{-# LANGUAGE OverloadedStrings #-}

-- | @Z12Sys = ℚ(ζ₁₂)@ —— 十二律的本源代数载体（4 维，坐标 ∈ ℚ，禁浮点）。
--
-- 参考 @Sovereign.Algebra.Character.DCCharacter@（Agda）：
--
-- > record Z12Sys : Set where
-- >   re   : ℚ   -- 1 分量
-- >   icpt : ℚ   -- i 分量
-- >   gam  : ℚ   -- γ = √-3 分量
-- >   igm  : ℚ   -- iγ 分量
-- > -- 载体：(a,b,c,d) ↦ a + b·i + c·γ + d·iγ
-- >
-- > -- 乘法（i² = -1, γ² = -3, iγ = γi 双线性展开）：
-- > --   1  分量: aa' - bb' - 3cc' + 3dd'
-- > --   i  分量: ab' + ba' - 3(cd' + dc')
-- > --   γ  分量: ac' + ca' - (bd' + db')
-- > --   iγ 分量: ad' + da' + bc' + cb'
-- >
-- > ζ₃ = -1/2 + γ/2      zi = i      conjᶻ (a,b,c,d) = (a, -b, -c, d)
--
-- 维数 4 = @φ(12)@（欧拉函数）—— 这正与 @GF(81) = GF(3⁴)@ 的 4 维、
-- 以及 pyBitNet @HolographicState (a,b,c,d) ∈ Z⁴@ 的 4 维对应。
--
-- ⚠️ 宪法约束：坐标全部是 ℚ（定点整数比），**不使用任何浮点**。
module Sov.Z12Sys
  ( Q(..)
  , qnum
  , qadd
  , qsub
  , qmul
  , qneg
  , Z12(..)
  , z12zero
  , z12one
  , addZ
  , negZ
  , mulZ
  , conjZ
  , zeta3
  , zeta4
  , zeta12
  ) where

--------------------------------------------------------------------------------
-- 定点有理数（禁浮点）
--------------------------------------------------------------------------------

-- | 有理数 @num/den@，规范为 @den > 0@ 且 @gcd(num,den) = 1@。
data Q = Q Integer Integer deriving (Show, Eq)

-- | 构造并约分。
qnum :: Integer -> Integer -> Q
qnum _ 0 = error "Q: zero denominator"
qnum n d =
  let g = gcd n d
      (n', d') = (n `div` g, d `div` g)
  in if d' < 0 then Q (negate n') (negate d') else Q n' d'

qadd :: Q -> Q -> Q
qadd (Q a b) (Q c d) = qnum (a * d + c * b) (b * d)

qsub :: Q -> Q -> Q
qsub (Q a b) (Q c d) = qnum (a * d - c * b) (b * d)

qmul :: Q -> Q -> Q
qmul (Q a b) (Q c d) = qnum (a * c) (b * d)

qneg :: Q -> Q
qneg (Q a b) = Q (negate a) b

--------------------------------------------------------------------------------
-- Z12Sys = ℚ(ζ₁₂)
--------------------------------------------------------------------------------

-- | @(re, icpt, gam, igm)@ 对应 @a + b·i + c·γ + d·iγ@（@γ = √-3@，@iγ = γi@）。
data Z12 = Z12 Q Q Q Q deriving (Show, Eq)

z12zero :: Z12
z12zero = Z12 (qnum 0 1) (qnum 0 1) (qnum 0 1) (qnum 0 1)

z12one :: Z12
z12one = Z12 (qnum 1 1) (qnum 0 1) (qnum 0 1) (qnum 0 1)

addZ :: Z12 -> Z12 -> Z12
addZ (Z12 a b c d) (Z12 a' b' c' d') = Z12 (qadd a a') (qadd b b') (qadd c c') (qadd d d')

negZ :: Z12 -> Z12
negZ (Z12 a b c d) = Z12 (qneg a) (qneg b) (qneg c) (qneg d)

-- | 乘法：@i² = -1@、@γ² = -3@、@iγ = γi@ 的双线性展开（逐项照 Agda）。
mulZ :: Z12 -> Z12 -> Z12
mulZ (Z12 a b c d) (Z12 a' b' c' d') =
  Z12
    (qadd (qsub (qmul a a') (qmul b b')) (qmul (qnum 3 1) (qsub (qmul d d') (qmul c c'))))
    (qsub (qadd (qmul a b') (qmul b a')) (qmul (qnum 3 1) (qadd (qmul c d') (qmul d c'))))
    (qsub (qadd (qmul a c') (qmul c a')) (qadd (qmul b d') (qmul d b')))
    (qadd (qadd (qmul a d') (qmul d a')) (qadd (qmul b c') (qmul c b')))

-- | 复共轭（域自同构）：@i ↦ -i@、@γ ↦ -γ@，即 @(a,b,c,d) ↦ (a,-b,-c,d)@。
conjZ :: Z12 -> Z12
conjZ (Z12 a b c d) = Z12 a (qneg b) (qneg c) d

--------------------------------------------------------------------------------
-- 单位根
--------------------------------------------------------------------------------

-- | 三次单位根 @ζ₃ = -1/2 + γ/2@（@γ = √-3@）。
zeta3 :: Z12
zeta3 = Z12 (qnum (-1) 2) (qnum 0 1) (qnum 1 2) (qnum 0 1)

-- | 四次单位根 @ζ₄ = i@。
zeta4 :: Z12
zeta4 = Z12 (qnum 0 1) (qnum 1 1) (qnum 0 1) (qnum 0 1)

-- | 十二次单位根 @ζ₁₂ = ζ₃ · ζ₄@（因 @gcd(3,4)=1@，阶为 12）。
zeta12 :: Z12
zeta12 = mulZ zeta3 zeta4
