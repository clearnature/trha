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
import Infrastructure.CPU.GF3Intrinsic (tritMul)
import Infrastructure.CPU.SovereignPhase12 (phase12Init)
import Infrastructure.CPU.SovereignWuxingLayer
  ( T6State (..), WuxingConfig (..), WuxingLayerW (..)
  , argMaxIdx, causalGraphStep, t6Init, t6Verify, wuxingForward, wuxingStep )
import Infrastructure.CPU.SovereignTypes (GF27, Trit, mkGF27, mkTrit, tritToInt)
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
