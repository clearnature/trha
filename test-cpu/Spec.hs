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
import Infrastructure.CPU.SovereignLossGain
import Infrastructure.CPU.SovereignWuXing

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
      head lengSequenceDiv `shouldBe` 81
      head lengSequenceRound `shouldBe` 81

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

    it "十二律名：半音次序与损益次序是两个不同次序（都保留）" $ do
      tones
        `shouldBe` [ "黄钟", "大吕", "太簇", "夹钟", "姑洗", "仲吕"
                   , "蕤宾", "林钟", "夷则", "南吕", "无射", "应钟" ]
      lossGainTones
        `shouldBe` [ "黄钟", "林钟", "太簇", "南吕", "姑洗", "应钟"
                   , "蕤宾", "大吕", "夷则", "夹钟", "无射", "仲吕" ]
      -- 第 2 位：半音次序是「大吕」，损益次序是「林钟」—— 不可混用
      (tones !! 1) `shouldNotBe` (lossGainTones !! 1)

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
