-- | 全息 π = 144/46 的**原子对**表示 —— 照 Agda 权威
-- @/data/work/discrete-mathematics/src/Sovereign/Structology/HolographicPi.agda@ 实现。
--
-- == 权威的约束（原文）
--
-- > -- 全息 π 作为原子配对（PolarRep × ToroidalRep，禁止约分由类型保证）
-- > data PolarRep    : Set where polar-144    : PolarRep
-- > data ToroidalRep : Set where toroidal-46  : ToroidalRep
-- > -- 受控桥：原子 → ℕ（唯一的数值出口，显式命名，不参与任何"约分"运算）
-- > polarRepValue : PolarRep → ℕ
--
-- 也就是说：**144 与 46 是不可约的原子**，不允许被"约分"成 72/23，也不允许直接
-- 参与算术 —— 这条**数学约束由类型系统强制**，而不是靠约定。
--
-- == Haskell 里如何表达"不透明"
--
-- Agda 用"只有一个构造子的 data + 不导出构造子"表达不透明。Haskell 等价做法是
-- @newtype@ **且不导出构造子**，并且**不提供 @Num@ / @Fractional@ / @Real@ 实例** ——
-- 于是本模块之外：
--
--   · 无法拆开原子（只能经 'polarRepValue' / 'toroidalRepValue' 取出），
--   · 无法对原子做算术（`polar144 + polar144` 编译失败），
--   · 无法约分（`polarRepValue p / toroidalRepValue t` 即使能算，也已经是"离开类型系统"
--     的行为，而 'HoloPi' 本身**不提供**任何商/比值出口）。
--
-- 为什么不能用裸 @Int@（本仓此前的形态）：@Int@ 上的一切运算都合法，"144/46 是原子对"
-- 这条约束就只剩注释，编译器管不了 —— 见 @test-cpu/negative/HoloPiArithmetic.hs@。
module Sov.HoloPi
  ( -- * 原子（构造子**不导出**）
    PolarRep
  , ToroidalRep
  , HoloPi
    -- * 构造
  , polar144
  , toroidal46
  , holoPi
    -- * 唯一数值出口
  , polarRepValue
  , toroidalRepValue
    -- * 宪法常量（照 Agda 的 HoloPiNumerator / HoloPiDenominator）
  , holoPiNumerator
  , holoPiDenominator
  ) where

-- ---------------------------------------------------------------------------
-- 原子：不透明类型
-- ---------------------------------------------------------------------------

-- | 极向缠绕的原子表示（对应 Agda @PolarRep@）。
--
-- **构造子不导出** —— 外部只能通过 'polar144' 取唯一值，或经 'polarRepValue' 读其整数。
newtype PolarRep = PolarRep Int

-- | 环向缠绕的原子表示（对应 Agda @ToroidalRep@）。
newtype ToroidalRep = ToroidalRep Int

-- | 全息 π 的**原子对**（对应 Agda 的 @PolarRep × ToroidalRep@ 配对）。
--
-- 刻意**不提供**任何"求商/求比值"的出口：约分在类型层面被禁止。
data HoloPi = HoloPi PolarRep ToroidalRep

-- ---------------------------------------------------------------------------
-- 构造（唯一入口）
-- ---------------------------------------------------------------------------

-- | 极向缠绕原子：144（@I_h@ 阶 120 + 手征正四面体 24）。
polar144 :: PolarRep
polar144 = PolarRep 144

-- | 环向缠绕原子：46（C60 在 @I_h@ 下的独立基频数）。
toroidal46 :: ToroidalRep
toroidal46 = ToroidalRep 46

-- | 全息 π 的原子对 @(144, 46)@。
holoPi :: HoloPi
holoPi = HoloPi polar144 toroidal46

-- ---------------------------------------------------------------------------
-- 唯一数值出口（照 Agda 的受控桥）
-- ---------------------------------------------------------------------------

-- | @PolarRep → ℕ@ 的唯一出口。
polarRepValue :: PolarRep -> Int
polarRepValue (PolarRep n) = n

-- | @ToroidalRep → ℕ@ 的唯一出口。
toroidalRepValue :: ToroidalRep -> Int
toroidalRepValue (ToroidalRep n) = n

-- ---------------------------------------------------------------------------
-- 宪法常量（Agda 里这两个是 @refl@ 证明的分支）
-- ---------------------------------------------------------------------------

-- | @HoloPiNumerator = 144@（Agda @holoPiNumeratorIs144 = refl@）。
holoPiNumerator :: Int
holoPiNumerator = polarRepValue polar144

-- | @HoloPiDenominator = 46@（Agda @holoPiDenominatorIs46 = refl@）。
holoPiDenominator :: Int
holoPiDenominator = toroidalRepValue toroidal46
