-- | CPU 侧数学正确性套件（判据 C1：代数结构 ↔ 权威规范）。
--
-- 为什么不塞进 test/Spec.hs：主套件 2000+ 行；这里按"判据"主题独立成套件，
-- 便于逐条核对"仓内实现 ↔ 外部权威"的对应关系（见 docs/plans/verification-criteria.md）。
module Main (main) where

import Data.List (sort)
import Test.Hspec

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
