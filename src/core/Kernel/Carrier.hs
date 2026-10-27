-- | Kernel.Carrier — 内核载体（唯一入口，L12 层）
--
-- 定位（2026-10-26 人类裁定）：载体是**函数空间**，结构**像 Hopf 丛那样**——
-- 不是点集、不是点积几何、也不是"一个纤维"。
--
--   底空间   T⁶/A₄           135 类（`Sov.Math.Hopf.projClass`，全枚举验证）
--   纤维     C[A₄]           A₄ 上的函数空间，12 维（含忠实的 3 维矢量表示）
--   状态     **截面**        Section = 底空间 → 纤维，即 135 × 12 = 1620 个系数
--
-- 为什么状态是"截面"而不是"点"：
--   Hopf 投影 T⁶ → T⁶/A₄ **没有 A₄-等变的全局截面**（Agda `HopfConstruction`
--   已证：全零向量被整个 A₄ 固定 ⇒ 商不 effective）。所以"只看底空间"不足以
--   决定状态——必须额外携带纤维上的函数，这就是截面，也是"环比球更智能"的
--   类型级来源（记忆住在纤维里）。
--
-- 实现**全部**来自 `sov-math`（`Sov.Math.CarrierA4` / `Sov.Math.A4` / `Sov.Math.Hopf`），
-- 本模块不复制任何数学：一处定义、两处使用，避免「第二个实现无等价证明」。
--
-- 层纪律：内核只在 L12 工作。24 / 144 / 4320 属 CPU / 推理层，跨层混用属范畴混淆。
module Kernel.Carrier
  ( -- * 层声明
    Layer (..)
    -- * 纤维：C[A₄]
  , Point
  , Carrier
  , initialPoint
  , dimCarrier
    -- * Plancherel 内积与基
  , dotC
  , normC2
  , basisVec
  , zeroC
    -- * 底空间：T⁶/A₄
  , baseCard
  , projClass
    -- * 描述差（非不变量；见 sov-math Field 头部的 P1 裁定）
  , flatDim
  , effectiveDim
  , overcount
  , minFiberSize
  , maxFiberSize
  , uniformCoordsFaithful
  , overcountByOrbit
  , overcountDecomposition
  , equivariantSectionPossible
    -- * 旋量层（相位 α 阶 4）
  , SpinFiber
  , spinFiberCard
  , spinTotalCard
  , M2
  , alphaMat
  , phaseAct
    -- * 状态 = 关联丛的截面（索引是 BaseKey，越界在构造处被拒）
  , BaseKey, mkBaseKey, baseKeyValue, allBaseKeys
  , Section
  , zeroSection
  , constantSection
  , sectionNorm
  , isFraming
    -- * 分解（Plancherel 恒等式）
  , Irrep (..)
  , dimI
  , plancherelSum
    -- * 群（供判据/迁移使用）
  , A4
  , allA4
  , a4Card
  ) where

import Sov.Math.A4 (A4, allA4, a4Card, idA4)
import Sov.Math.CarrierA4
  ( Carrier
  , Irrep (..)
  , basisVec
  , dimCarrier
  , dimI
  , dotC
  , normC2
  , plancherelSum
  , zeroC
  )
import Sov.Math.Eis (Eis, eisZero)
import Sov.Math.Field
  ( BaseKey
  , allBaseKeys
  , baseKeyValue
  , effectiveDim
  , equivariantSectionPossible
  , flatDim
  , maxFiberSize
  , minFiberSize
  , mkBaseKey
  , overcount
  , overcountByOrbit
  , overcountDecomposition
  , uniformCoordsFaithful
  )
import Sov.Math.Hopf (baseCard, projClass)
import Sov.Math.SL23 (M2)
import Sov.Math.SpinHopf (SpinFiber, alphaMat, phaseAct, spinFiberCard, spinTotalCard)

-- | 内核工作的密度层。只声明 L12：其余层不进内核。
data Layer = L12 deriving (Eq, Show)

-- | 纤维 = C[A₄]（A₄ 上的函数空间，12 维自由 Z[ω]-模）
type Point = Carrier

-- | 初态（纤维内）= δ_e：A₄ 单位元处的基向量（L² 基的一员）
initialPoint :: Point
initialPoint = basisVec idA4

--------------------------------------------------------------------------------
-- 状态 = 关联丛的截面：底空间 T⁶/A₄ → 纤维 C[A₄]
--------------------------------------------------------------------------------

-- | 截面：底空间（`BaseKey`，只能由 `mkBaseKey` 造）→ 纤维 C[A₄]
type Section = BaseKey -> Carrier

-- | 零截面（不构成 framing：处处为零）
zeroSection :: Section
zeroSection _ = zeroC

-- | 常截面：每个底点都取同一纤维向量（取 δ_e 时是真 framing）
constantSection :: Point -> Section
constantSection p _ = p

-- | 逐点 Plancherel 范数（未归一，= 12·‖·‖²）。判据按点做，不按整体做。
sectionNorm :: Section -> BaseKey -> Eis
sectionNorm s b = normC2 (s b)

-- | framing 判据：截面**处处非零**。
--
-- 这是 Hopf 非平凡性的证人：主丛无全局截面 ⇒ 纤维上的"朝向"不能被底空间平凡化；
-- 存在无处为零的截面（framing）当且仅当丛可平凡化。故本判据是内核里唯一
-- 能区分"球层"与"环层"的开关。
isFraming :: Section -> Bool
isFraming s = all (\b -> sectionNorm s b /= eisZero) allBaseKeys

--------------------------------------------------------------------------------
-- 层间常数（只读；不引入新的运行时状态）
--
-- 这些是**丛的结构常数**，不是新的层：
--   · flatDim 1620 / effectiveDim 729 ⇒ overcount 891：**只是两个描述的差，不是不变量**
--     （典范的事实是 Σ_b |fiber(b)| = 729；1620 是平凡丛的截面维数；两者之间无典范映射）
--   · minFiberSize 1 / maxFiberSize 12 ⇒ uniformCoordsFaithful = False
--     （存在 1 点轨道 ⇒ 无法用统一的 12 坐标忠实描述整丛）
--   · spinFiberCard 9 / spinTotalCard 6561、alphaMat 阶 4（α² = −I）
--------------------------------------------------------------------------------
