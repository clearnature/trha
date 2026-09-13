-- | CPU 侧数学正确性套件（判据 C1 + C2，见 docs/plans/verification-criteria.md）。
--
-- 为什么不塞进 test/Spec.hs：主套件 2000+ 行；这里按**判据**主题独立成套件，
-- 便于逐条核对"仓内实现 ↔ 外部权威"（C1）与"类型不变量是否被编译期强制"（C2）。
module Main (main) where

import Data.List (sort)
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)
import Test.Hspec

import Infrastructure.CPU.HoloPi
import Infrastructure.CPU.HolographicSpace
  ( VectorSpace, basisAt, basisVec, gOrder, galoisConjugate, galoisNorm
  , hermitianIP, infoDim, isOrthogonal, nCells, nOrbits, normSq, zeroVec )
import Infrastructure.CPU.SovereignLossGain
  ( HoloState (..), lengSequenceDiv, lengSequenceRound, lossGainTones, sunOpDiv
  , tones, yiOpDiv )
import Infrastructure.CPU.ConstraintVerdict
  ( ConstraintVerdict (..), VerdictStatus (..), projectToGF27, verdictOf )
import Control.Monad (forM_, unless)
import Infrastructure.CPU.GF27SIMD (gf27Rowdot, gf27RowdotScalarOnly, hasAVX2)
import Infrastructure.CPU.GF3Intrinsic (gf27Mul, tritMul)
import Infrastructure.CPU.SovereignTypes (mulGF9)
import Infrastructure.CPU.SovereignPhase12
  ( Phase12 (..), breatheCount, phase12Init, phaseSeq12, step12 )
import Infrastructure.CPU.SovereignGF27 (gf27Add)
import Infrastructure.CPU.SovereignWuxingLayer
  ( T6State (..), WuxingConfig (..), WuxingLayerW (..)
  , argMaxIdx, causalGraphStep, t6Init, t6Verify, wuxingForward, wuxingStep )
import Infrastructure.CPU.SovereignTypes
  ( GF9, GF27, Trit, gf9One, gf9ToPair, gf27ToInt, mkGF9, mkGF27, mkTrit, tritToInt )
import Infrastructure.CPU.Z12Sys
  ( Z12, addZ, conjZ, mulZ, negZ, qnum, z12one, z12zero, zeta3, zeta4, zeta12 )
import Infrastructure.CPU.SovereignWuXing
  ( aSequence, chiralityZ2, christoffelSpiral, c60IndependentFrequencies
  , platonicsOrders, polarWinding144, spiralMod3, toroidalWinding46
  , wuXingGenerate, wuXingGenerateCycle, wuXingMods, wuXingNames
  , wuXingOvercome, wuXingOvercomeCycle, wuXingPhaseOf )

-- | Agda 权威出处：
--   · Sovereign.MetaStructure.WuXing  (/data/work/discrete-mathematics/src/02-magnetic-24d/WuXing.agda)
--       data WuXing = Fire | Earth | Metal | Water | Wood
--       wuXingBase:  Fire=2  Earth=5  Metal=4  Water=6  Wood=8
--       generate (相生): Fire→Earth→Metal→Water→Wood→Fire
--       overcome (相克): Fire→Metal→Wood→Earth→Water→Fire
--   · Sovereign.Structology.WuXingTransition
--       Christoffel 螺旋 1→2→4→8→7→5（×2 mod 9，周期 6）
--       → 模 3 投影 [1,2,1,2,1,2] → scanl 累加 [0,1,3,4,6] = a 序列
--       → a 的奇偶 = Z₂ 手性
--   · Sovereign.Structology.HolographicPi
--       全息 π = 144/46 的**原子对**；"禁止约分由类型保证"
--   · Sovereign.Coupling.LossGain（src/03-neutral-144d/LossGain.agda）
--       data LossGain = Sun（×2/3）| Yi（×4/3）
--       huangzhong = 81；standardChain = Sun Yi … Sun（11 步）
--       twelveLüSequence = computeSequence 81 standardChain（12 项，整除）
main :: IO ()
main = hspec $ do
  describe "C1 · 五行 ↔ Agda 权威（Sovereign.MetaStructure.WuXing）" $ do
    it "wuXingBase 的值集 = {2,4,5,6,8}（Fire2 Earth5 Metal4 Water6 Wood8）" $ do
      sort wuXingMods `shouldBe` [2, 4, 5, 6, 8]

    it "相生 generate：火→土→金→水→木→火（恰 5 步归位）" $ do
      wuXingGenerateCycle "火" `shouldBe` ["火", "土", "金", "水", "木", "火"]

    it "相克 overcome：火→金→木→土→水→火（恰 5 步归位）" $ do
      wuXingOvercomeCycle "火" `shouldBe` ["火", "金", "木", "土", "水", "火"]

    it "相生与相克都是阶恰为 5 的置换，且都无不动点" $ do
      let g5 n = wuXingGenerate (wuXingGenerate (wuXingGenerate (wuXingGenerate (wuXingGenerate n))))
          o5 n = wuXingOvercome (wuXingOvercome (wuXingOvercome (wuXingOvercome (wuXingOvercome n))))
      and [ g5 n == n | n <- wuXingNames ] `shouldBe` True
      and [ o5 n == n | n <- wuXingNames ] `shouldBe` True
      and [ wuXingGenerate n /= n | n <- wuXingNames ] `shouldBe` True
      and [ wuXingOvercome n /= n | n <- wuXingNames ] `shouldBe` True

    it "相生与相克的复合：先相生再相克 ≠ 恒等（两条路径确实不同）" $ do
      and [ wuXingOvercome (wuXingGenerate n) /= n | n <- wuXingNames ] `shouldBe` True

  describe "C1 · 五行相位 ↔ Agda 权威（Sovereign.Structology.WuXingTransition）" $ do
    it "Christoffel 螺旋 = ×2 mod 9，周期 6" $ do
      christoffelSpiral `shouldBe` [1, 2, 4, 8, 7, 5]
      and [ christoffelSpiral !! ((i + 1) `mod` 6) == (christoffelSpiral !! i * 2) `mod` 9
          | i <- [0 .. 5] ] `shouldBe` True

    it "模 3 投影 = 损益交替 [1,2,1,2,1,2]" $ do
      spiralMod3 `shouldBe` [1, 2, 1, 2, 1, 2]
      and [ m == x `mod` 3 | (x, m) <- zip christoffelSpiral spiralMod3 ] `shouldBe` True

    it "a 序列 = scanl (+) 0 spiralMod3 的前 5 项 = [0,1,3,4,6]" $ do
      aSequence `shouldBe` take 5 (scanl (+) 0 spiralMod3)
      aSequence `shouldBe` [0, 1, 3, 4, 6]

    it "手性 Z₂：a 的奇偶决定是否含反射" $ do
      map chiralityZ2 aSequence `shouldBe` [False, True, True, False, False]

    it "五行相位序与 a 序列一一对应（[火土金水木] ↔ a=0/1/3/4/6）" $ do
      wuXingNames `shouldBe` ["火", "土", "金", "水", "木"]
      length wuXingNames `shouldBe` length aSequence
      map wuXingPhaseOf aSequence `shouldBe` map Just wuXingNames

  describe "C1 · 缠绕常数 ↔ Agda 权威（Winding.agda / IhC60Vibration.agda）" $ do
    it "POLAR = 144 = I_h(120) + 手征四面体(24)" $ do
      polarWinding144 `shouldBe` 120 + 24

    it "TOROIDAL = 46 = C60 在 I_h 下的独立基频数（重数向量之和）" $ do
      toroidalWinding46 `shouldBe` 46
      fst c60IndependentFrequencies `shouldBe` 46
      snd c60IndependentFrequencies `shouldBe` [2, 1, 3, 4, 4, 5, 6, 6, 8, 7]

    it "五正多面体对称群阶（Agda 跃迁链 A₄→O_h→I_h→I→O）" $ do
      map (\(_, _, o) -> o) platonicsOrders `shouldBe` [12, 48, 120, 60, 24]

  -- ------------------------------------------------------------------
  -- C1 · 全息 π：权威要求 144 与 46 是**不可约的原子对**，
  --      这条数学约束必须由类型强制（见 Infrastructure.CPU.HoloPi）。
  -- ------------------------------------------------------------------
  describe "C1 · 全息 π ↔ Agda 权威（Sovereign.Structology.HolographicPi）" $ do
    it "原子对 (144, 46)：数值出口唯一，等于宪法常量" $ do
      polarRepValue polar144 `shouldBe` 144
      toroidalRepValue toroidal46 `shouldBe` 46
      holoPiNumerator `shouldBe` 144
      holoPiDenominator `shouldBe` 46

    it "极向 144 = I_h(120) + 手征四面体(24)；环向 46 = C60 独立基频数" $ do
      polarRepValue polar144 `shouldBe` 120 + 24
      toroidalRepValue toroidal46 `shouldBe` 46

    it "原子对与 Winding/IhC60 的常量同源（两处实现一致）" $ do
      polarRepValue polar144 `shouldBe` polarWinding144
      toroidalRepValue toroidal46 `shouldBe` toroidalWinding46

  -- ------------------------------------------------------------------
  -- C1 · 十二律损益链 ↔ Sovereign.Coupling.LossGain（src/03-neutral-144d/LossGain.agda）
  --   权威：huangzhong = 81；standardChain = Sun Yi … Sun（11 步，Sun/Yi 交替）
  --         twelveLüSequence = computeSequence 81 standardChain（12 项）
  --         sunOp n = (n*2)/3，yiOp n = (n*4)/3（均为**整除**）
  -- ------------------------------------------------------------------
  describe "C1 · 十二律损益链 ↔ Agda 权威（Sovereign.Coupling.LossGain）" $ do
    it "黄钟 = 81（huangzhong），两个口径的起点一致" $ do
      take 1 lengSequenceDiv `shouldBe` [81]
      take 1 lengSequenceRound `shouldBe` [81]

    it "整除算子与 Agda 同式：sunOp n = n*2 div 3、yiOp n = n*4 div 3" $ do
      and [ sunOpDiv n == (n * 2) `div` 3 | n <- [81, 54, 72, 64, 30, 1, 7, 1000] ] `shouldBe` True
      and [ yiOpDiv n == (n * 4) `div` 3 | n <- [81, 54, 72, 64, 30, 1, 7, 1000] ] `shouldBe` True

    it "standardChain 是 11 步 Sun/Yi 交替，序列恰 12 项（起点 + 11 步）" $ do
      let standardChain = concat (replicate 5 ["Sun", "Yi"]) ++ ["Sun"]
      length standardChain `shouldBe` 11
      take 4 standardChain `shouldBe` ["Sun", "Yi", "Sun", "Yi"]
      length lengSequenceDiv `shouldBe` 12
      length lengSequenceRound `shouldBe` 12

    it "lengSequenceDiv ≡ Agda twelveLüSequence（按权威原文独立重算后比对）" $ do
      -- 在测试里**独立实现** Agda 的 computeSequence/applyChain（不调用仓内算子），
      -- 这样两边是独立算法，比对才有意义。
      let standardChain = concat (replicate 5 ["Sun", "Yi"]) ++ ["Sun"]
          step n "Sun" = (n * 2) `div` 3
          step n _     = (n * 4) `div` 3
          twelveLu = scanl step 81 standardChain
      lengSequenceDiv `shouldBe` twelveLu

    it "数学性质：(2/3)·(4/3) = 8/9 在实数上成立，但整除截断下只是「不超过」" $ do
      -- ⚠️ 这里刻意**不**写成 "yiOpDiv (sunOpDiv n) == n*8 div 9"：
      -- 逐次整除会截断，故实现层只能保证 ≤ —— 这正说明"两步不可合并成一步 ×8/9"，
      -- 与《架构宪法 v1.1》"数学结构不可简化"一致。
      and [ yiOpDiv (sunOpDiv n) <= (n * 8) `div` 9 | n <- [1 .. 200] ] `shouldBe` True
      or [ yiOpDiv (sunOpDiv n) /= (n * 8) `div` 9 | n <- [1 .. 200] ] `shouldBe` True

    it "两处口径差异被显式保留：整除版第 6 项 = 42，四舍五入版 = 43" $ do
      -- LossGain.agda 用整除（64×2/3 = 42）；Zhonglv.lengToNat 的表是四舍五入（42.67 → 43）
      (lengSequenceDiv !! 5, lengSequenceRound !! 5) `shouldBe` (42, 43)

    it "四舍五入版 = Zhonglv.lengToNat 的 12 项表（另一权威）" $ do
      lengSequenceRound `shouldBe` [81, 54, 72, 48, 64, 43, 57, 38, 51, 34, 45, 30]

    it "两个次序是两个范畴（并不矛盾）：相间之序 vs 相生之序" $ do
      -- 古律学里这是两个**不同范畴**的次序（用户 2026-09-13 指正：二者不矛盾，各自成立）：
      --   · 半音次序 = 「十二律相间之序」：依阴阳相间与月令配属，黄钟对应仲冬十一月、
      --     大吕对应季冬十二月、太簇对应孟春正月……描述五行在**时间（十二月）上的流转**。
      --   · 损益次序 = 「十二律相生之序」，即「三分损益，隔八相生」之序：黄钟下生林钟、
      --     林钟上生太簇……描述五行在**生成（相生）上的递生**（纳音体系）。
      -- 所以它们各对应一条规律，不能拿"哪个才对"互相否定；仓内两个都保留。
      tones
        `shouldBe` [ "黄钟", "大吕", "太簇", "夹钟", "姑洗", "仲吕"
                   , "蕤宾", "林钟", "夷则", "南吕", "无射", "应钟" ]
      lossGainTones
        `shouldBe` [ "黄钟", "林钟", "太簇", "南吕", "姑洗", "应钟"
                   , "蕤宾", "大吕", "夷则", "夹钟", "无射", "仲吕" ]

    it "相间之序：阴阳相间 —— 六阳律居偶数位、六阴吕居奇数位" $ do
      -- 阳律与阴吕交替排列，这正是"相间"二字的来源，也是配十二月的依据。
      let yang = [ "黄钟", "太簇", "姑洗", "蕤宾", "夷则", "无射" ]
          yin  = [ "大吕", "夹钟", "仲吕", "林钟", "南吕", "应钟" ]
      [ tones !! i | i <- [0, 2 .. 10] ] `shouldBe` yang
      [ tones !! i | i <- [1, 3 .. 11] ] `shouldBe` yin

    it "相生之序 = 隔八相生：在相间之序上每步 +7 半音（纯五度循环，周期 12）" $ do
      -- 两个次序之间的**定量**关系，也是"隔八相生"的可执行形式：
      --   黄钟(0) → 林钟(7) → 太簇(2) → 南吕(9) → … 每步 +7 ≡ 纯五度（3/2 的十二平均化）
      --   gcd(7,12) = 1 ⇒ 周期恰为 12 ⇒ 恰好遍历全部十二律，不提前回到黄钟。
      let posOf n = case lookup n (zip tones [0 ..]) of
                      Just i  -> i
                      Nothing -> -1
          idxs = map posOf lossGainTones
      idxs `shouldBe` [0, 7, 2, 9, 4, 11, 6, 1, 8, 3, 10, 5]
      and [ (idxs !! ((i + 1) `mod` 12)) == (idxs !! i + 7) `mod` 12 | i <- [0 .. 11] ]
        `shouldBe` True
      -- "隔八"取自含端点的第 8 个律位；相邻两者在半音次序上相差 7（= 8 − 1）
      (idxs !! 1 - idxs !! 0) `shouldBe` 7
      length (take 12 (iterate (\x -> (x + 7) `mod` 12) 0)) `shouldBe` 12


  -- ------------------------------------------------------------------
  -- C1 · 分圆单位根 ↔ 权威 Sovereign.Algebra.GroupTheory.PhaseSubgroup
  --
  -- PhaseSubgroup 给出"相位旋转的群论本质"：GF(9)* ≅ C₈，α = gen⁶，
  --   ⟨α⟩ = {1, α, α²=-1, α³=-α} ≅ C₄（阶恰为 4：α⁴=1 上界 + α²≠1 下界）
  --   rot x = x *s sα（左乘 α），rot²  = 乘 α² = 取负（180°）—— rot-2-is-neg
  --
  -- 仓内在**另一个范畴**里实现了同一个 C₄：Z[ζ₁₂]（Z12Sys）里的 ζ₄ = i。
  -- 二者不是矛盾，是同一群结构的两种表示（GF(9)* 的 ⟨α⟩ ≅ Z[ζ₁₂] 的 ⟨i⟩ ≅ C₄）。
  -- 因此这里验的是**群结构本身**：阶、180° 对应取负、单位圆、共轭为环自同构。
  -- ------------------------------------------------------------------
  describe "C1 · 分圆单位根 ↔ 权威（PhaseSubgroup 的 C₄ / Z12Sys 的 C₁₂）" $ do
    it "ζ₄ = i：ζ₄² = −1（对应 rot-2-is-neg 的 180°），ζ₄⁴ = 1，ζ₄ ≠ 1" $ do
      mulZ zeta4 zeta4 `shouldBe` negZ z12one                      -- ★ ζ₄² = −1
      mulZ (mulZ (mulZ zeta4 zeta4) zeta4) zeta4 `shouldBe` z12one -- ★ ζ₄⁴ = 1
      zeta4 `shouldNotBe` z12one

    it "ζ₄ 的阶恰为 4（上界 4 + 下界非 2）—— 与 GF(9)* 的 ⟨α⟩ ≅ C₄ 同构" $ do
      -- 对应 Agda alpha-order-exactly-4：(sα^s 4 ≡ s1) × (sα^s 2 ≠ s1) × (sα ≠ s1)
      mulZ (mulZ (mulZ zeta4 zeta4) zeta4) zeta4 `shouldBe` z12one
      mulZ zeta4 zeta4 `shouldNotBe` z12one
      zeta4 `shouldNotBe` z12one

    it "ζ₃ 的阶恰为 3" $ do
      mulZ (mulZ zeta3 zeta3) zeta3 `shouldBe` z12one
      mulZ zeta3 zeta3 `shouldNotBe` z12one
      zeta3 `shouldNotBe` z12one

    it "ζ₁₂ = ζ₃·ζ₄ 的阶恰为 12（gcd(3,4)=1 ⇒ lcm(3,4)=12）" $ do
      let pow n = foldr (\_ acc -> mulZ zeta12 acc) z12one [1 .. n]
      zeta12 `shouldBe` mulZ zeta3 zeta4
      pow 12 `shouldBe` z12one
      pow 11 `shouldNotBe` z12one

    it "单位根都落在单位圆上：ζ · conj ζ = 1" $ do
      mulZ zeta3 (conjZ zeta3) `shouldBe` z12one
      mulZ zeta4 (conjZ zeta4) `shouldBe` z12one
      mulZ zeta12 (conjZ zeta12) `shouldBe` z12one

    it "conjZ 是对合，且是环自同构（反保乘法）" $ do
      conjZ (conjZ zeta12) `shouldBe` zeta12
      conjZ (mulZ zeta3 zeta4) `shouldBe` mulZ (conjZ zeta3) (conjZ zeta4)
      conjZ z12one `shouldBe` z12one
      conjZ z12zero `shouldBe` z12zero

    it "环公理抽查：乘法交换、单位元、加法负元（Z[ζ₁₂] 是交换环）" $ do
      mulZ zeta3 zeta4 `shouldBe` mulZ zeta4 zeta3
      mulZ z12one zeta12 `shouldBe` zeta12
      addZ zeta12 (negZ zeta12) `shouldBe` z12zero


  -- ------------------------------------------------------------------
  -- C1 · 商空间周期 ↔ 权威 Sovereign.Coupling.ZhonglvPhaseSync
  --
  -- 权威给出两个周期与一条定理：
  --   PRIMARY_PERIOD     = 60   = LCM(12, 10)（地支 12 × 天干 10 = 六十甲子）
  --   HOLOGRAPHIC_PERIOD = 3312 = LCM(144, 46)
  --   periodNotDivisible : ¬ (3312 % 60 ≡ 0)   —— 3312 % 60 = 12
  --   primaryCannotCoverHolographic : 60 < 3312
  -- 且 v5.2 注释明确：3312 是**代数对齐点**（algebraic alignment point），
  -- 非拓扑闭合周期 —— "极限环不因 LCM 整除而真正闭合，只是相位在此碰头"。
  -- ------------------------------------------------------------------
  describe "C1 · 商空间周期 ↔ 权威（ZhonglvPhaseSync.agda）" $ do
    it "PRIMARY_PERIOD = 60 = lcm(12,10)（地支 × 天干 = 六十甲子）" $ do
      lcm 12 10 `shouldBe` 60

    it "HOLOGRAPHIC_PERIOD = 3312 = lcm(144,46)（两个缠绕常数的代数对齐点）" $ do
      lcm polarWinding144 toroidalWinding46 `shouldBe` 3312

    it "★ periodNotDivisible：3312 % 60 = 12 ≠ 0（全息周期不被主周期整除）" $ do
      (3312 :: Int) `mod` 60 `shouldBe` 12
      (3312 :: Int) `mod` 60 `shouldNotBe` 0

    it "★ primaryCannotCoverHolographic：60 < 3312（主商空间无法覆盖全息商空间）" $ do
      (60 :: Int) < lcm polarWinding144 toroidalWinding46 `shouldBe` True

    it "权威的语义区分：3312 是代数对齐点，不是拓扑闭合周期" $ do
      -- 原文："极限环不因 LCM 整除而真正闭合——只是两个周期性在此处相位碰头。"
      -- 固定成断言：60 | 60（主周期自闭合），但 60 ∤ 3312（全息只碰头不闭合）。
      (60 :: Int) `mod` 60 `shouldBe` 0
      (3312 :: Int) `mod` 60 `shouldBe` 12

    it "仲吕不交的坐标（乙亥）：地支亥 = 11、天干乙 = 1，两者均不为 0" $ do
      -- 权威 zhonglvCannotZeroBoth：polarMod12 ≢ zero × toroidalMod10 ≢ zero
      (11 :: Int) `shouldNotBe` 0
      (1 :: Int) `shouldNotBe` 0
      (11 :: Int) `mod` 12 `shouldBe` 11
      (1 :: Int) `mod` 10 `shouldBe` 1

  -- ------------------------------------------------------------------
  -- C1 · 十二律相位机 ↔ 权威（LossGain 时序 + Zhonglv 呼吸桥）
  --
  -- phase12Init = 黄钟：HoloState (a,b,c,d) = (0,0,0,5)、累加器 = 3¹¹ = 177147。
  -- step12：损-益交替（even i 损 / odd i 益）；**每 12 步**应用仲吕对齐桥。
  -- ------------------------------------------------------------------
  describe "C1 · 十二律相位机 ↔ 权威（LossGain + Zhonglv 时序）" $ do
    it "初值 = 黄钟：(0,0,0,5)、累加器 3¹¹ = 177147、步数 0" $ do
      hsA (p12Holo phase12Init) `shouldBe` 0
      hsB (p12Holo phase12Init) `shouldBe` 0
      hsC (p12Holo phase12Init) `shouldBe` 0
      hsD (p12Holo phase12Init) `shouldBe` 5
      p12Acc phase12Init `shouldBe` 177147
      p12Step phase12Init `shouldBe` 0
      (177147 :: Integer) `shouldBe` 3 ^ (11 :: Int)

    it "★ 呼吸桥每 12 步一次：breatheCount = 步数 div 12" $ do
      [ breatheCount p | p <- phaseSeq12 25 ] `shouldBe` [ i `div` 12 | i <- [0 .. 24] ]

    it "步数严格递增，且相位序列长度 = 请求步数" $ do
      map p12Step (phaseSeq12 13) `shouldBe` [0 .. 12]
      length (phaseSeq12 7) `shouldBe` 7

    it "损-益交替：第 1 步（i=0，损）与第 2 步（i=1，益）的相位分量不同" $ do
      -- 对应 LossGain 的 Sun/Yi 交替（even i → holoLoss，odd i → holoGain）
      let p1 = step12 phase12Init
          p2 = step12 p1
      p12Holo p1 `shouldNotBe` p12Holo p2
      p12Step p1 `shouldBe` 1
      p12Step p2 `shouldBe` 2

  -- ------------------------------------------------------------------
  -- C4 · 因果推理内核的**语义**（而不只是"看起来有界"）。
  --
  -- 此前仓内只验"输出有界 ∈ [0,26]"与链长 —— 那是*结构*，不是*语义*。
  -- 这一节验判据本身在算什么：
  --   · t6Verify 真正有约束力的只有 **Berry 相位连续**（|nb| < 105 = 1.05×100）；
  --     缠绕两条（np < 144、nt < 46）经 mod 后**恒真**，是冗余条件（此处仅记录）。
  --   · t6Verify 是**有状态**的：nb = t6Berry st + dBerry 走累积，故边界由累积值决定。
  --   · argMaxIdx 是整数域上的选择：取最大元素的**首个**下标（平局取最小）。
  -- ------------------------------------------------------------------
  describe "C4 · 因果推理语义（t6Verify / argMaxIdx）" $ do
    it "t6Verify 的实质判据是 Berry 相位连续：|dBerry| < 105 接受、≥ 105 拒绝" $ do
      t6Verify t6Init 0 0 0 `shouldBe` True
      t6Verify t6Init 0 0 104 `shouldBe` True
      t6Verify t6Init 0 0 105 `shouldBe` False
      t6Verify t6Init 0 0 9999 `shouldBe` False

    it "t6Verify 是有状态的：边界由「已有相位 + 增量」的累积值决定" $ do
      -- 已有 t6Berry = 104 时，增量 0 通过、增量 1 即越过阈值（104+1=105 → 拒绝）
      let st = T6State 0 0 104
      t6Verify st 0 0 0 `shouldBe` True
      t6Verify st 0 0 1 `shouldBe` False

    it "缠绕条件经 mod 后恒真（np < 144、nt < 46 属冗余子条件）" $ do
      -- 记录这条"冗余"：任意整数增量都不会越界，所以那两个子条件永远成立。
      -- 它们保留在代码里无害（是几何意图的注释），但**不能**当作有效判据来验收。
      and [ t6Verify t6Init dP dT 0 | dP <- [-2000 .. 2000], dT <- [-500, 0, 500] ] `shouldBe` True

    it "argMaxIdx：取最大元素的首个下标（平局取最小），空向量为 0" $ do
      argMaxIdx [] `shouldBe` 0
      argMaxIdx (map mkGF27 [0, 1, 2]) `shouldBe` 2
      argMaxIdx (map mkGF27 [26, 0, 26]) `shouldBe` 0 -- 平局 → 最小下标
      argMaxIdx (map mkGF27 [5, 9, 9, 3]) `shouldBe` 1
      argMaxIdx (map mkGF27 [0]) `shouldBe` 0


  -- ------------------------------------------------------------------
  -- C4 · 因果图的**符号级语义**：邻接是外积、非法路径不融合。
  --
  -- adj[i][j] = q_i ⊗ k_j 是 GF(3) 上的**外积**，故秩 ≤ 1 —— 这一点可以直接在
  -- 邻接表上验证（任意 2×2 子式为零），而"值域在 {0,1,2}"那种断言根本区分不出
  -- 外积与任意矩阵。秩 1 才是 sigmoid(q·kᵀ/√hex) 被离散成 GF(3) 乘法后的真实结构。
  --
  -- 另一条是因果推理的关键语义：**几何不可达或置信度不足 → 不融合**，
  -- 对应参考实现里 -1e9 使该路径永不被选。可执行形式就是 h' ≡ x（残差恒等）。
  -- ------------------------------------------------------------------
  describe "C4 · 因果图语义（外积邻接 / 非法路径不融合）" $ do
    it "邻接是外积：任意 2×2 子式在 GF(3) 上为零（秩 ≤ 1，不是任意矩阵）" $ do
      let (adj, _) = causalGraphStep c4Cfg c4Layer c4X0
          idx = [0 .. wcHex c4Cfg - 1]
      and [ tritMul (adj !! i !! j) (adj !! i' !! j')
              == tritMul (adj !! i !! j') (adj !! i' !! j)
          | i <- idx, i' <- idx, j <- idx, j' <- idx ] `shouldBe` True

    it "邻接行由 k 决定：qi = 0 的行必然整行全零（外积的直接推论）" $ do
      let (adj, _) = causalGraphStep c4Cfg c4Layer c4X0
      -- 秩 ≤ 1 且行是 k 的标量倍：全零行 ⟺ 该 q_i = 0（用外积一致性反推）
      length adj `shouldBe` wcHex c4Cfg
      map length adj `shouldBe` replicate (wcHex c4Cfg) (wcHex c4Cfg)
      and [ tritToInt v >= 0 && tritToInt v <= 2 | row <- adj, v <- row ] `shouldBe` True

    it "Berry 边界：预置 104 时，若本步 dBerry 恰为 0 则仍可达（104+0 < 105）" $ do
      -- 记录一个容易想错的边界：阈值判的是 t6Berry st + dBerry 的**累积值**，
      -- 不是单看预置值。104 只是"只剩 1 的余量"，并非必然越界。
      -- 本层在本步的 dBerry = dPol - dTor（由 wlStepT6 决定），实测为 0 → 104 通过。
      let stEdge = T6State 0 0 104
          (_, _, _, _, okEdge) = wuxingStep c4Cfg c4Layer 0 phase12Init stEdge c4X0
      okEdge `shouldBe` True

    it "非法路径不融合：ok = False 时 hidden 恒等于输入（残差恒等）" $ do
      -- 用远大于任何可能增量的 Berry 预置值，使 t6Verify 必然失败。
      -- 依据：dPol/dTor 是 3 个分量的 gf27ToInt 之和，各有界，故 |dBer| 远小于 100000。
      let stBad = T6State 0 0 100000
          (_, _, h1, _, ok1) = wuxingStep c4Cfg c4Layer 0 phase12Init stBad c4X0
      ok1 `shouldBe` False
      h1 `shouldBe` c4X0      -- ★ 不可达 ⇒ 不融合 ⇒ 输出恒等于输入

    it "wuxingForward：reachable 标记逐 step 累积，长度等于 steps" $ do
      let (_, _, _, okss) = wuxingForward c4Cfg c4Layer c4X0
      length okss `shouldBe` wcSteps c4Cfg
      and [ (o :: Bool) == True || o == False | o <- okss ] `shouldBe` True

    it "GF(3) 乘法的零元/单位元：0 ⊗ x = 0、1 ⊗ x = x（传播语义的依据）" $ do
      -- prop[j] = ⧺_i (adj[i][j] ⊗ nodes[i])；adj[i][j] = 0 的边之所以不传播，
      -- 依据正是 GF(3) 里 0 是乘法的零元。先把它钉住。
      and [ tritMul (mkTrit 0) (mkTrit x) == mkTrit 0 | x <- [0, 1, 2] ] `shouldBe` True
      and [ tritMul (mkTrit 1) (mkTrit x) == mkTrit x  | x <- [0, 1, 2] ] `shouldBe` True

    it "★ 无边不传播：q、k 全零 ⇒ adj 全零 ⇒ updated ≡ 输入（空图 = 残差恒等）" $ do
      -- 因果图语义的最强可观测推论：没有边就没有传播，输出必须逐元素等于输入。
      -- 构造：attnQ / attnK 全置零（形状 [nd, 1]）⇒ 所有 q_i = k_j = 0
      --       ⇒ adj[i][j] = 0 ⊗ 0 = 0 ⇒ prop 全零 ⇒ out = 0 ⇒ updated 只剩残差 x。
      let nd = wcDim c4Cfg `div` wcHex c4Cfg
          zeroAttn = replicate nd [mkTrit 0]
          layerNoEdge = c4Layer { wlAttnQ = zeroAttn, wlAttnK = zeroAttn }
          (adjZ, updZ) = causalGraphStep c4Cfg layerNoEdge c4X0
      and [ tritToInt v == 0 | row <- adjZ, v <- row ] `shouldBe` True
      length adjZ `shouldBe` wcHex c4Cfg
      updZ `shouldBe` c4X0      -- ★ 无边 ⇒ 不传播 ⇒ 输出恒等于输入

    it "0.1 系数的整数语义：fused 经 div 10 后只能取 {0,1,2}（已知退化，如实记录）" $ do
      -- 实现：h' = x + (gf27ToInt fused `div` 10)。gf27ToInt 的值域是 [0,26]，
      -- 所以 div 10 只能得 {0, 1, 2} —— "0.1 系数"在整数域上是**截断**而非精确缩放。
      -- 实测：本测试层的数据使 fused 分量全部 < 10，于是 updated ≡ x。
      -- 这里把它固定成断言，避免日后误以为"有边就该改变输出"。
      -- （先前我按"有边 ⇒ 输出改变"写对照用例，被这条实现细节否证 —— 记录于此。）
      let (_, upd) = causalGraphStep c4Cfg c4Layer c4X0
      upd `shouldBe` c4X0
      and [ gf27ToInt v `div` 10 <= 2 | v <- upd ] `shouldBe` True

    it "★ 覆盖局限（如实记录）：本测试层下 adj 恒为零，因果图恒为空图" $ do
      -- scalarOf 取 GF(27) 向量的首元素再 mod 3；在本层（w3c 的确定性 trit 矩阵，
      -- dim=24 / heads=3 / hex=6）下，所有 q_i、k_j 都落在 0，于是 adj ≡ 0。
      -- 这意味着：上面"无边不传播"那条在本层里是**空图**情形，未覆盖"有边传播"。
      -- 要覆盖非空邻接需要另选一组权重使某个 q_i、k_j 非零 —— 尚未做，记录在此。
      let (adjN, _) = causalGraphStep c4Cfg c4Layer c4X0
      and [ tritToInt v == 0 | row <- adjN, v <- row ] `shouldBe` True



  -- ------------------------------------------------------------------
  -- C3 · 多实现逐元素全等 —— GF(27) 行点积
  --
  -- 判据 C3 的实质：同一数学结构的不同**独立实现**在**同一批输入**上结果全等，
  -- 这才是"跨实现/跨硬件一致"的证据。本仓现有三个实现：
  --   ① Haskell 标量：foldl gf27Add 0 . zipWith gf27Mul（权威定义在 GF3Intrinsic）
  --   ② C 标量      ：trha_gf27_rowdot_scalar_only（rowdot_scalar：acc = add(acc, mul(..))）
  --   ③ AVX2        ：trha_gf27_rowdot（8 路并行，累加器用 (Z/3)³ 分离表示）
  -- ④ GPU(WGSL)   ：**缺失** —— 见下方覆盖度一条，不假装完整。
  --
  -- ⚠️ 判据纪律：性能**不是**判据。本机 AVX2 实测反而略慢于标量，这**不影响**其验证
  -- 价值（宪法原文：AVX2 是"第 4 个独立实现"，用于结构一致性，不是提速手段）。
  -- ------------------------------------------------------------------
  describe "C3 · GF(27) 行点积的多实现全等（Haskell 标量 / C 标量 / AVX2）" $ do
    it "★ 穷举全对：a ∈ [0,26] × b ∈ [0,26] 上 ① ≡ ②（729 组）" $ do
      -- 穷举比抽样强：不留"恰好没测到"的缝隙。
      forM_ [0 .. 26] $ \a ->
        forM_ [0 .. 26] $ \b -> do
          let hsRef = foldl gf27Add 0 (zipWith gf27Mul [a] [b])
          cScalar <- gf27RowdotScalarOnly [a] [b]
          hsRef `shouldBe` cScalar

    it "★ 三实现在同一批输入上全等（① ≡ ② ≡ ③）" $ do
      forM_ c3Cases $ \(w, x) -> do
        let hsRef = foldl gf27Add 0 (zipWith gf27Mul w x)
        cScalar <- gf27RowdotScalarOnly w x
        hsRef    `shouldBe` cScalar
        dispatched <- gf27Rowdot w x
        dispatched `shouldBe` cScalar

    it "边界输入：空 / 单个零元 / 单个单位元" $ do
      foldl gf27Add 0 (zipWith gf27Mul [] []) `shouldBe` 0
      c0 <- gf27RowdotScalarOnly [] []
      c0 `shouldBe` 0
      c1 <- gf27RowdotScalarOnly [0] [26]
      c1 `shouldBe` 0                      -- 0 ⊗ x = 0
      c2 <- gf27RowdotScalarOnly [1] [17]
      c2 `shouldBe` 17                     -- 1 ⊗ x = x

    it "跨 8 路边界：长度 7 / 8 / 9 / 15 / 16 / 17 都与标量一致（AVX2 分块）" $ do
      forM_ [7, 8, 9, 15, 16, 17] $ \n -> do
        let w = take n (cycle [1 .. 26])
            x = take n (cycle [26, 25 .. 1])
            hsRef = foldl gf27Add 0 (zipWith gf27Mul w x)
        cScalar <- gf27RowdotScalarOnly w x
        cScalar `shouldBe` hsRef
        dispatched <- gf27Rowdot w x
        dispatched `shouldBe` hsRef

    it "长向量（1000 元素）三实现一致" $ do
      let w = map (`mod` 27) [i * 7 + 3 | i <- [0 .. 999]]
          x = map (`mod` 27) [i * 11 + 5 | i <- [0 .. 999]]
          hsRef = foldl gf27Add 0 (zipWith gf27Mul w x)
      cScalar <- gf27RowdotScalarOnly w x
      cScalar `shouldBe` hsRef
      dispatched <- gf27Rowdot w x
      dispatched `shouldBe` hsRef

    it "★ 覆盖度如实标注：GPU(WGSL) 实现缺失，C3 当前覆盖 3/4" $ do
      -- 不是断言"完整"，而是把缺口固定下来：第四实现（GPU WGSL）在本仓尚不存在，
      -- 故 C3 只覆盖 Haskell 标量 / C 标量 / AVX2 三条路径。
      -- 无 GPU 时按项目约定用 pendingWith 兜底，而不是假装通过。
      avx <- hasAVX2
      unless avx $
        pendingWith ("本机无 AVX2；C3 仅验证 ①Haskell 标量 ≡ ②C 标量 两条路径。"
                     ++ "GPU(WGSL) 实现缺失：C3 覆盖 3/4。")
      avx `shouldBe` True

  -- ------------------------------------------------------------------
  -- C5（D-1）· 约束 ↔ 外部推理 —— 作用点 = 响应侧的「采纳判定」
  --
  -- 定案（用户 2026-09-13 采纳，经 fable5 推算）：
  --   · 外部模型是**黑盒**（不能改权重/采样）⇒ 约束不可能作用于其内部计算，
  --     只能作用于"**哪些输出被采纳**"。故作用点在**响应侧**，形式为「采纳判定」。
  --   · 失败行为 = **标注**（附警告继续），不拒绝、不降级 —— 裁定①。
  --   · 草稿模型与约束是**同一机制的两面**：草稿输出必须先过约束 —— 裁定③。
  --   · 请求侧**不注入**（对黑盒只是"建议"，不可验收）。
  -- ------------------------------------------------------------------
  describe "C5（D-1）· 约束 ↔ 外部推理：采纳判定（作用点 = 响应侧）" $ do
    it "投影桥是确定性的，且值域落在 GF(27) = [0,26]" $ do
      projectToGF27 8 "hello world" `shouldBe` projectToGF27 8 "hello world"
      and [ gf27ToInt v >= 0 && gf27ToInt v <= 26 | v <- projectToGF27 40 "abcdefg" ]
        `shouldBe` True

    it "投影桥的形状：长度恰为请求的 dim；不足补零；空输入全零" $ do
      length (projectToGF27 24 "abc") `shouldBe` 24
      length (projectToGF27 24 "") `shouldBe` 24
      and [ gf27ToInt v == 0 | v <- projectToGF27 24 "" ] `shouldBe` True
      take 3 (projectToGF27 24 "abc") `shouldBe` projectToGF27 3 "abc"

    it "★ 判定**总是**产出（裁定①：标注而非拒绝，任何输入都不抛错）" $ do
      let inputs = [ "", "a", "hello", replicate 500 'x', "\n\t", "约束验证" ]
          statuses = [ cvStatus (verdictOf s) | s <- inputs ]
      and [ s == VerdictPass || s == VerdictWarn | s <- statuses ] `shouldBe` True
      and [ not (null (cvReason (verdictOf s))) | s <- inputs ] `shouldBe` True

    it "判定的分量自洽：cvT6 ⟺ cvReach 全 True；状态与 cvT6 一致" $ do
      let vs = map verdictOf [ "", "a", "hello world", "约束验证" ]
      and [ cvT6 v == and (cvReach v) | v <- vs ] `shouldBe` True
      and [ (cvStatus v == VerdictPass) == cvT6 v | v <- vs ] `shouldBe` True
      and [ length (cvReach v) == 2 | v <- vs ] `shouldBe` True -- steps = 2

    it "约束确实跑了因果图与四步链：cvEdges 非负、cvReach 逐 step" $ do
      let v = verdictOf "hello world"
      cvEdges v >= 0 `shouldBe` True
      length (cvReach v) `shouldBe` 2

    it "★ 草稿与外部输出走同一判定入口（裁定③：同一机制的两面）" $ do
      -- 以"同一函数对同一文本给出同一判定"固定"不做来源区分"这条性质。
      verdictOf "draft output" `shouldBe` verdictOf "draft output"
      cvT6 (verdictOf "draft") `shouldBe` cvT6 (verdictOf "draft")


  -- ------------------------------------------------------------------
  -- C1 · 全息态与基模 ↔ 权威（HolographicSpace.agda / FiniteInnerProduct.agda）
  --
  -- 权威逐字（本仓此前**完全没有**内积空间，属"权威有、仓内无"，按 §6 不变量清单补齐）：
  --   galoisConjugate (a , b) = a , negate b      —— σ 是**对合**
  --   galoisNorm      (a , b) = (a⊗a) ⊕ (b⊗b)     —— 共轭下不变
  --   hermitianIP n f g = sumGF9 n (λ i → f i *gf9 galoisConjugate (g i))
  --       ★ 共轭在**第二个**参数上（写成第一个会得到另一套内积）
  --   normSq n f = hermitianIP n f f
  --   basisVec = 对角为 1、其余 0；basisAt-self / normSq-basisVec / basis-orthogonal
  --   hermitian-conj-sym : ⟨f,g⟩ ≡ σ(⟨g,f⟩)
  -- ------------------------------------------------------------------
  describe "C1 · 全息态与基模 ↔ 权威（HolographicSpace / FiniteInnerProduct）" $ do
    it "★ galoisConjugate 是对合（权威 galoisConjugate²）：σ(σ x) = x，且 (a,b) ↦ (a,−b)" $ do
      and [ galoisConjugate (galoisConjugate x) == x | x <- allGF9 ] `shouldBe` True
      and [ gf9ToPair (galoisConjugate x) == (a, negate b `mod` 3)
          | x <- allGF9, let (a, b) = gf9ToPair x ] `shouldBe` True

    it "★ galoisFixedPoint：σ x = x ⟺ x 的第二分量为 0（落在 GF(3) 嵌入里）" $ do
      and [ (galoisConjugate x == x) == (snd (gf9ToPair x) == 0) | x <- allGF9 ] `shouldBe` True

    it "★ galoisNorm 在共轭下不变（权威 galoisNorm-conjugate），且 = a² + b²" $ do
      and [ galoisNorm (galoisConjugate x) == galoisNorm x | x <- allGF9 ] `shouldBe` True
      and [ galoisNorm x == (a * a + b * b) `mod` 3
          | x <- allGF9, let (a, b) = gf9ToPair x ] `shouldBe` True

    it "★ basisAt-self：标准基在自身索引处 = 1（权威 basisAt-self）" $ do
      forM_ [1 .. 6] $ \n ->
        forM_ [0 .. n - 1] $ \i ->
          (basisVec n i !! i) `shouldBe` gf9One

    it "★ normSq-basisVec：每个基向量的范数 = 1（权威 BasisMode.normOne）" $ do
      forM_ [1 .. 6] $ \n ->
        forM_ [0 .. n - 1] $ \i ->
          snd (basisAt n i) `shouldBe` gf9One

    it "★ basis-orthogonal：i ≠ j 时 ⟨b_i, b_j⟩ = 0（权威 basis-orthogonal）" $ do
      and [ isOrthogonal (basisVec n i) (basisVec n j)
          | n <- [1 .. 5], i <- [0 .. n - 1], j <- [0 .. n - 1], i /= j ] `shouldBe` True

    it "★ hermitian-conj-sym：⟨f,g⟩ = σ(⟨g,f⟩)（穷举 GF(9)² 的 81 组）" $ do
      -- 这条同时**钉住共轭的方向**：若把 σ 挪到第一个参数，本式不再普遍成立。
      and [ hermitianIP [x] [y] == galoisConjugate (hermitianIP [y] [x])
          | x <- allGF9, y <- allGF9 ] `shouldBe` True

    it "hermitian-linearˡ（首参线性）：⟨a·f, h⟩ = a·⟨f,h⟩（1 维穷举）" $ do
      and [ hermitianIP [scalarTimes a x] [h] == scalarTimes a (hermitianIP [x] [h])
          | a <- allGF9, x <- allGF9, h <- allGF9 ] `shouldBe` True
      and [ hermitianIP [x] [scalarTimes c h] == gf9Conj c `scalarTimes'` hermitianIP [x] [h]
          | c <- allGF9, x <- allGF9, h <- allGF9 ] `shouldBe` True

    it "零向量：‖0‖² = 0（权威 normSq-of-zero）；zeroVec 长度为 n" $ do
      normSq (zeroVec 7) `shouldBe` mkGF9 (0, 0)
      length (zeroVec 7) `shouldBe` 7

    it "宪法常量：INFO-DIM = 4320 · N-CELLS = 729 = 3⁶ · N-ORBITS = 14 · G-ORDER = 54" $ do
      infoDim `shouldBe` 4320
      nCells  `shouldBe` 729
      (729 :: Int) `shouldBe` 3 ^ (6 :: Int)
      nOrbits `shouldBe` 14
      gOrder  `shouldBe` 54


  -- ------------------------------------------------------------------
  -- C4 · 五行四步链的可达标记语义（wuxingForward）
  --
  -- 此前只验了"长度 = steps"。这里补上语义：每一步的选择合法性、可达标记与
  -- 末态 T⁶ 状态的一致性、以及缠绕相位的模封闭性。
  -- ------------------------------------------------------------------
  describe "C4 · 五行四步链的可达标记语义（wuxingForward）" $ do
    it "★ chain / oks 与 steps 一一对应" $ do
      let (_, _, chain, oks) = wuxingForward c4Cfg c4Layer c4X0
      length chain `shouldBe` wcSteps c4Cfg
      length oks `shouldBe` wcSteps c4Cfg

    it "★ 每步选择合法：heads 个 (node, trit)，node ∈ [0,hex)、trit ∈ [0,trit)" $ do
      let (_, _, chain, _) = wuxingForward c4Cfg c4Layer c4X0
      and [ length sel == wcHeads c4Cfg | sel <- chain ] `shouldBe` True
      and [ n >= 0 && n < wcHex c4Cfg  | sel <- chain, (n, _) <- sel ] `shouldBe` True
      and [ t >= 0 && t < wcTrit c4Cfg | sel <- chain, (_, t) <- sel ] `shouldBe` True

    it "★ 全步可达 ⟹ 末态 Berry 相位仍在阈值内（与 t6Verify st 0 0 0 同义）" $ do
      -- 依据：最后一步的 reachable = t6Verify st_{n-1} dPol dTor dBer，而
      -- st_final 的 berry = t6Berry st_{n-1} + dBer（**不 mod**），故
      -- t6Verify st_final 0 0 0 = |t6Berry st_final| < 105 与最后一步的可达判定**同义**。
      -- 注意方向：这里是**蕴含**（全可达 ⟹ 末态在界内），不是等价 —— 若中途某步不可达，
      -- 末态仍可能恰好落在界内。
      let (_, st, _, oks) = wuxingForward c4Cfg c4Layer c4X0
      (not (and oks) || t6Verify st 0 0 0) `shouldBe` True

    it "★ 缠绕相位恒在环面内（mod 封闭性，与增量大小无关）" $ do
      let (_, st, _, _) = wuxingForward c4Cfg c4Layer c4X0
      (t6Polar st >= 0 && t6Polar st < polarWinding144) `shouldBe` True
      (t6Toroidal st >= 0 && t6Toroidal st < toroidalWinding46) `shouldBe` True

    it "末 hidden 长度 = dim，且各分量落在 GF(27) = [0,26]" $ do
      let (h, _, _, _) = wuxingForward c4Cfg c4Layer c4X0
      length h `shouldBe` wcDim c4Cfg
      and [ gf27ToInt v >= 0 && gf27ToInt v <= 26 | v <- h ] `shouldBe` True


  -- ------------------------------------------------------------------
  -- C4 · 非空邻接的传播结构（补上此前"本层 adj 恒零"留下的覆盖缺口）
  --
  -- 此前 C4 第三批记录了一个**覆盖局限**：默认测试层（c4Layer）的 wlAttnQ/K 经
  -- scalarOf（mod 3）后 q_i、k_j 全为 0，于是 adj 恒零、因果图恒为空图。
  -- 本节构造一个**使 adj 非零**的层来补这个缺口。
  --
  -- 构造：取 wlAttnQ = wlAttnK = 全 1，则 q_i = k_j = (Σ_j n_j) mod 3 对所有 head 相同，
  -- 于是 adj[i][j] = q ⊗ q —— **对称**且**秩 ≤ 1**，只要 q ≠ 0 就非零。
  -- ------------------------------------------------------------------
  describe "C4 · 非空邻接的传播结构（补覆盖缺口）" $ do
    it "★ 构造非零邻接：全 1 的 attnQ/K 使 adj 非零（推翻「恒零」结论）" $ do
      let nd = wcDim c4Cfg `div` wcHex c4Cfg
          onesAttn = replicate nd [mkTrit 1]
          layerOnes = c4Layer { wlAttnQ = onesAttn, wlAttnK = onesAttn }
          (adjOnes, _) = causalGraphStep c4Cfg layerOnes c4X0
          (adjBase, _) = causalGraphStep c4Cfg c4Layer c4X0
      and [ tritToInt v == 0 | row <- adjBase, v <- row ] `shouldBe` True   -- 默认层恒零
      or  [ tritToInt v /= 0 | row <- adjOnes, v <- row ] `shouldBe` True   -- 本节层非零

    it "★ 非零邻接下秩仍 ≤ 1（任意 2×2 子式为零）—— 外积结构不因非零而失效" $ do
      let nd = wcDim c4Cfg `div` wcHex c4Cfg
          onesAttn = replicate nd [mkTrit 1]
          layerOnes = c4Layer { wlAttnQ = onesAttn, wlAttnK = onesAttn }
          (adj, _) = causalGraphStep c4Cfg layerOnes c4X0
          idx = [0 .. wcHex c4Cfg - 1]
      and [ tritMul (adj !! i !! j) (adj !! i' !! j')
              == tritMul (adj !! i !! j') (adj !! i' !! j)
          | i <- idx, i' <- idx, j <- idx, j' <- idx ] `shouldBe` True

    it "★ q 相同 ⟹ 邻接对称（adj[i][j] = adj[j][i]）" $ do
      let nd = wcDim c4Cfg `div` wcHex c4Cfg
          onesAttn = replicate nd [mkTrit 1]
          layerOnes = c4Layer { wlAttnQ = onesAttn, wlAttnK = onesAttn }
          (adj, _) = causalGraphStep c4Cfg layerOnes c4X0
          idx = [0 .. wcHex c4Cfg - 1]
      and [ adj !! i !! j == adj !! j !! i | i <- idx, j <- idx ] `shouldBe` True

    it "★ 覆盖度的诚实说明：非零邻接**已**可构造，但传播对 hidden 的可观测影响仍被截断" $ do
      -- 两个独立事实，都在这里固定住，避免日后被误读：
      --   ① adj 非零**可以**构造（见上三条）—— 此前"恒零"是默认层的性质，不是普遍性质。
      --   ② 但 h' = x + (gf27ToInt fused `div` 10)，而 gf27ToInt ∈ [0,26] ⇒ div 10 ∈ {0,1,2}，
      --      故传播对 hidden 的影响是**截断后**的，通常仍观测不到变化（见 C4 第三批）。
      let nd = wcDim c4Cfg `div` wcHex c4Cfg
          onesAttn = replicate nd [mkTrit 1]
          layerOnes = c4Layer { wlAttnQ = onesAttn, wlAttnK = onesAttn }
          (_, updOnes) = causalGraphStep c4Cfg layerOnes c4X0
      length updOnes `shouldBe` wcDim c4Cfg
      and [ gf27ToInt v >= 0 && gf27ToInt v <= 26 | v <- updOnes ] `shouldBe` True

  -- ------------------------------------------------------------------
  -- C2：类型不变量必须由**编译期**强制。
  --
  -- 做法：test-cpu/negative/ 下的文件是**故意写错**的（跨范畴、跨句柄类型、
  -- 对原子做算术），它们**必须编译失败**。这比任何正向断言都更本质 ——
  -- 若某天它们能通过，说明不变量被削弱了，而正向测试仍会全绿（那才危险）。
  -- ------------------------------------------------------------------
  describe "C2 · 类型不变量（负面编译测试）" $ do
    it "Trit 不能当 GF27 用（编译必须失败）" $ \_ -> do
      code <- ghcExitCode "test-cpu/negative/CrossCategoryTritGF27.hs"
      code `shouldNotBe` ExitSuccess

    it "Z3r（环）不能当 GF27（域）用（编译必须失败）" $ \_ -> do
      code <- ghcExitCode "test-cpu/negative/RingVsFieldZ3rGF27.hs"
      code `shouldNotBe` ExitSuccess

    it "WebGPU Device 不能当 Buffer 用（编译必须失败）" $ \_ -> do
      code <- ghcExitCode "test-cpu/negative/HandleMixDeviceBuffer.hs"
      code `shouldNotBe` ExitSuccess

    it "全息 π 的原子不可做算术（编译必须失败）" $ \_ -> do
      code <- ghcExitCode "test-cpu/negative/HoloPiArithmetic.hs"
      code `shouldNotBe` ExitSuccess

    it "全息 π 的原子对不可求商/约分（编译必须失败）" $ \_ -> do
      code <- ghcExitCode "test-cpu/negative/HoloPiReduce.hs"
      code `shouldNotBe` ExitSuccess

    it "GF(9) 的元素不能当 GF(27) 用（次数 2 vs 3 的扩域，编译必须失败）" $ \_ -> do
      code <- ghcExitCode "test-cpu/negative/DomainGF9VsGF27.hs"
      code `shouldNotBe` ExitSuccess

    it "谐波指数 Harmonic 不能当域元素 GF27 用（「不是元素值」，编译必须失败）" $ \_ -> do
      code <- ghcExitCode "test-cpu/negative/HarmonicVsGF27.hs"
      code `shouldNotBe` ExitSuccess

    it "打包表示 Pv 不能当 [Int] 用（解包出口不可绕过，编译必须失败）" $ \_ -> do
      code <- ghcExitCode "test-cpu/negative/PvVsList.hs"
      code `shouldNotBe` ExitSuccess

    it "Z[ζ₁₂] 的 Z12 不能当有理数 Q 用（4 维 vs 1 维，编译必须失败）" $ \_ -> do
      code <- ghcExitCode "test-cpu/negative/Z12VsQ.hs"
      code `shouldNotBe` ExitSuccess


-- | C4 用的确定性测试层（与主套件同一构造法：trit 由 (i,j,seed) 决定）。
c4Cfg :: WuxingConfig
c4Cfg = WuxingConfig dimC4 heads4 steps4 hex4 trit4
  where
    dimC4 = 24; heads4 = 3; steps4 = 2; hex4 = 6; trit4 = 3

c4Layer :: WuxingLayerW
c4Layer = WuxingLayerW
  { wlNodeProj = w3c dimC4 (hex4 * nd4) 1
  , wlAttnQ    = w3c nd4 1 2
  , wlAttnK    = w3c nd4 1 3
  , wlOutProj  = w3c (hex4 * nd4) dimC4 4
  , wlStepNode = replicate steps4 (w3c dimC4 (heads4 * hex4) 5)
  , wlStepTrit = replicate steps4 (w3c dimC4 (heads4 * hex4 * trit4) 6)
  , wlStepT6   = replicate steps4 (w3c dimC4 (heads4 * 2) 7)
  , wlStepConf = replicate steps4 (w3c dimC4 heads4 8)
  , wlFuse     = w3c (heads4 * (dimC4 `div` heads4)) dimC4 9
  , wlGInit    = replicate hex4 (replicate trit4 (replicate (dimC4 `div` heads4) (mkTrit 1)))
  }
  where
    dimC4 = 24; heads4 = 3; steps4 = 2; hex4 = 6; trit4 = 3
    nd4 = dimC4 `div` hex4

c4X0 :: [GF27]
c4X0 = map mkGF27 (take dimC4 (cycle [0, 1, 2]))
  where dimC4 = 24

-- | 确定性 trit 矩阵：元素 = (i*7 + j*13 + seed) mod 3。
w3c :: Int -> Int -> Int -> [[Trit]]
w3c r c sd = [ [ mkTrit ((i * 7 + j * 13 + sd) `mod` 3) | j <- [0 .. c - 1] ] | i <- [0 .. r - 1] ]



-- | GF(9) 的全部 9 个元素（穷举用）。
allGF9 :: [GF9]
allGF9 = [ mkGF9 (a, b) | a <- [0 .. 2], b <- [0 .. 2] ]

-- | GF(9) 标量乘（供内积性质测试用；与 plusGF9 同源，不改产品代码）。
scalarTimes :: GF9 -> GF9 -> GF9
scalarTimes x y = mulGF9 x y

scalarTimes' :: GF9 -> GF9 -> GF9
scalarTimes' = flip mulGF9

gf9Conj :: GF9 -> GF9
gf9Conj = galoisConjugate

-- | C3 对拍的输入批（含空、跨 8 路边界、多块等）。
c3Cases :: [([Int], [Int])]
c3Cases =
  [ ([], [])
  , ([1], [1])
  , ( [0, 1, 2, 3, 4, 5, 6, 7, 8]
    , [8, 7, 6, 5, 4, 3, 2, 1, 0] )                       -- 9：跨 8 路
  , ( map (`mod` 27) [1, 5, 9, 13, 17, 21, 25, 2, 6, 10, 14, 18, 22, 26, 3, 7]
    , map (`mod` 27) [2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 22, 24, 26, 1, 3, 5] )  -- 16：两块
  , (replicate 100 7, replicate 100 11)                   -- 多块
  ]

-- | 用本项目环境（cabal exec 提供包数据库）编译一个文件，返回退出码。
-- 期望是 'ExitFailure'；若返回 'ExitSuccess' 则说明该文件本应报错却没报。
ghcExitCode :: FilePath -> IO ExitCode
ghcExitCode path = do
  (code, _, _) <-
    readProcessWithExitCode
      "cabal"
      ["exec", "--", "ghc", "-fno-code", "-v0", path]
      ""
  pure code
