{-# LANGUAGE OverloadedStrings #-}

-- | 层1/层2 的__原生整数__算子 —— 与 @sov-math@ 的 C++ 实现逐位对应。
--
-- 参考（@\/home\/yanli\/work\/math\/cpp\/include\/gf3_layer2.h@）：
--
-- > :27   z3r_mul           层1 GF(3) 乘  = TRIT_MUL_LUT
-- > :38   z3r_add_carry     层2 逢三进一 (sum, carry) = ((a+b+c)%3, (a+b+c)/3)
-- > :51   z3r_norm          层1 范数 |T₀|=0, |T₁|=1, |T₂|=1
-- > :79   z3r_dot_product   层2 Σ GF(3)乘（整数累加，__不归约__）
-- > :105  z3r_matmul        层1 Σ GF(3)乘 → % 3
-- > :129  z3r_gate          层2 non_zero << 16 > threshold_q16 → T1 : T0
-- > :148  z3r_gated_mul     层1 gate ⊗ x
-- > :178  a4_flip_triple    层2 A4 翻转 (C3 顺/逆/自同构/手性交换)
-- > :205  build_rsqrt_lut_q16  层0→2 round(1/√(m/dim+eps) × 2¹⁶)
-- > :216  z3r_rms_norm      层2 (prod×rsqrt + 2¹⁵) >> 16 再 % 3
--
-- 与 "GF3Ops" 的关系：那边是__浮点__实现（对应 Python/torch 参考），这边是__纯整数__实现
-- （对应电性文明复位后的本源表达，见 @Sovereign\/Projection.agda@ 与
-- @Sovereign\/Algebra\/Duodecimal.agda@）。两者并存，互不替换：
-- 浮点版是投影读数，整数版每步 % 3 归约，状态有限 ⟹ 必然落入极限环。
module Sov.GF3Intrinsic
  ( fxpShift
  , fxpOne
  , fxpHalf
  , tritMul
  , tritNorm
  , z3rAddCarry
  , rsqrtLutQ16
  , z3rRmsNorm
  , z3rDotProduct
  , z3rMatmul
  , z3rGate
  , z3rGatedMul
  , z3rSwiGLU
    -- GF(27) 载体（Sovereign.Algebra.GF27）
  , gf27Decode
  , gf27Encode
  , gf27Mul
  , gf27MulRef
  , gf27MulTable
  , gf27MulCyclic
  , gf27PowEnc
  , gf27LogTable
  , gf27ExpTable
  , gf27FrobeniusVec
  , gf27FrobeniusLog
    -- 本源相位层（DuodecClock: 加乘联合周期，非 C₁₂ 投影）
  , AlphaPower(..)
  , mulAlpha
  , alphaInv
  , alphaPowerToGF9
  , gf9Mul
  , DuodecPoint
  , mixedOp
  , duodecE
  , crt12
  , mixedOpN
  , zeroOblivionPeriod
  , phaseTrajectory
  ) where

import qualified Data.Vector.Unboxed as V
import Sov.Types (Trit, mkTrit, tritToInt)
import qualified Data.Vector.Unboxed.Mutable as MV

--------------------------------------------------------------------------------
-- 层0: Q16 定点（仲吕边界 2¹⁶）
--------------------------------------------------------------------------------

fxpShift, fxpOne, fxpHalf :: Int
fxpShift = 16          -- ZHONGLV_SHIFT
fxpOne   = 65536       -- ZHONGLV_BOUNDARY = 2¹⁶
fxpHalf  = 32768       -- 2¹⁵，定点乘的舍入项

--------------------------------------------------------------------------------
-- 层1: GF(3) 域运算（3 ≡ 0，每 trit 独立）
--------------------------------------------------------------------------------

-- | @z3r_mul@ = @TRIT_MUL_LUT[a][b]@：GF(3) 乘法。
tritMul :: Trit -> Trit -> Trit
tritMul a b = mkTrit (tritToInt a * tritToInt b)

-- | @z3r_norm@ = @TRIT_NORM_LUT@：|0|=0，|1|=1，|2|=1（2²=4≡1 mod 3）。
tritNorm :: Trit -> Trit
tritNorm a = mkTrit (if tritToInt a == 0 then 0 else 1)

--------------------------------------------------------------------------------
-- 层2: Z/3¹¹Z 环运算（3 ≠ 0，逢三进一）
--------------------------------------------------------------------------------

-- | @z3r_add_carry@：本位 = (a+b+carry) mod 3，进位 = (a+b+carry) div 3。
z3rAddCarry :: Int -> Int -> Int -> (Int, Int)
z3rAddCarry a b carryIn = (total `mod` 3, total `div` 3)
  where total = a + b + carryIn

-- | @build_rsqrt_lut_q16@：@lut[m] = round(1/√(m/dim + eps) × 2¹⁶)@。
rsqrtLutQ16 :: Int -> Double -> [Int]
rsqrtLutQ16 dim eps =
  [ round (65536 / sqrt (fromIntegral m / fromIntegral dim + eps)) | m <- [0 .. dim] ]

-- | @z3r_rms_norm@：非零计数取 rsqrt，GF(3) 乘 gamma，Q16 定点乘后归约回 {0,1,2}。
z3rRmsNorm :: [Int] -> [Trit] -> [Trit] -> [Trit]
z3rRmsNorm lut gamma x =
  [ mkTrit (((tritToInt (tritMul (x !! j) (gamma !! (j `mod` length gamma))) * rsqrt
              + fxpHalf) `div` fxpOne) `mod` 3)
  | j <- [0 .. length x - 1] ]
  where rsqrt = lut !! length (filter (\t -> tritToInt t /= 0) x)

-- | @z3r_dot_product@：层2 的点积 —— Σ GF(3)乘，__整数累加不归约__（值域 [0, 2·dim]）。
z3rDotProduct :: [Trit] -> [Trit] -> Int
z3rDotProduct a b = sum [ tritToInt (tritMul x y) | (x, y) <- zip a b ]

-- | @z3r_matmul@：层1 矩阵乘 —— 点积后 @% 3@ 归约（3 ≡ 0）。
--
-- ⚠️ 归约在这里做，不在 'z3rDotProduct'：后者是**层2**语义（整数累加不归约）。
z3rMatmul :: [[Trit]] -> [Trit] -> [Trit]
z3rMatmul w x = [ mkTrit (z3rDotProduct row x) | row <- w ]

-- | @z3r_gate@：层2 √3 门控 —— 用__非零计数__与 Q16 阈值做整数比较。
-- 能隙 Δ = √3，阈值取 Δ² × 2¹⁶ = 3 × 65536。
z3rGate :: Int -> Int -> Trit
z3rGate nonZero thresholdQ16 = mkTrit (if (nonZero * fxpOne) > thresholdQ16 then 1 else 0)

-- | @z3r_gated_mul@：层1 gate ⊗ x（GF(3) 乘，不是浮点乘）。
z3rGatedMul :: Trit -> [Trit] -> [Trit]
z3rGatedMul g = map (tritMul g)

-- | SwiGLU 的本源形式：@z3r_gate@ 判定 → @z3r_gated_mul@ → down 投影归约。
-- 全部在 {0,1,2} 上闭运算，因此输出必然仍是 trit。
z3rSwiGLU :: [[Trit]] -> [[Trit]] -> [[Trit]] -> [Trit] -> [Trit]
z3rSwiGLU gateW upW downW x = z3rMatmul downW gated
  where
    g     = z3rMatmul gateW x                       -- 已是 GF(3) trit 向量
    u     = z3rMatmul upW x
    gate  = z3rGate (length (filter (\t -> tritToInt t /= 0) g)) (3 * fxpOne)   -- 阈值 Δ² = 3
    gated = z3rGatedMul gate u

--------------------------------------------------------------------------------
-- 本源相位层: DuodecClock —— 加乘联合周期
--
-- 参考 Sovereign.Algebra.GroupTheory.DuodecClock（Agda, 0 postulate）:
--   §1  AlphaPower = {1, α, α², α³} ⊂ GF(9)*，ord(α) = 4，α² = −1
--   §2  DuodecPoint = Trit × AlphaPower，mixedOp (x,a) (y,b) = (x ⊕ y, mulAlpha a b)
--   §6b ZeroOblivion: ⊕ 分量 ⊕³ = id (char 3)，α 分量 α⁴ = id (ord 4)，联合 LCM = 12
--
-- ⚠️ 这不是 C₁₂ 循环群、也不是 C₃×C₄ 直积：它是"加法步进 ⊕ 乘法旋转"的联合周期。
-- C₁₂ 只是它的加法投影（写出来会有零因子 2×6≡0）。
--------------------------------------------------------------------------------

-- | ⟨α⟩ = GF(9)* 的 4 阶乘法子群。
data AlphaPower = A0 | A1 | A2 | A3
  deriving (Show, Eq, Ord, Enum, Bounded)

-- | @AlphaPower@ 作为 **GF(9) 的元素**（不是 4 个整数序号）。
--
-- 权威：@Sovereign/Algebra/GF9.agda@
--
-- > GF9 = GF3 × GF3          -- (a, b) = a + bα,  α² = -1
-- > alpha-powers-4 : (α·α)·(α·α) ≡ 1        -- α 的阶恰为 4
-- > §11 子群格: {1} ⊂ {1,2} ⊂ {1,α,2,2α} ⊂ GF(9)*
-- >                               阶 4 ↑      ≅ C8
-- > 命名层锚点: char 3 中 α 阶 4，90° 生光；φ = 1+2α 是 8 阶元(45° 半步)，α = φ⁶
--
-- 即 @A0..A3@ 是 **C₄ ⊂ GF(9)* ≅ C₈** 的四个元素，**携带 90° 矢量相位**
-- （与球谐旋转相关），而非抽象序号。它们的 @GF(9)@ 形态：
--
-- @A0 = 1 = (1,0)@、@A1 = α = (0,1)@、@A2 = α² = −1 = (2,0)@、@A3 = α³ = −α = (0,2)@
alphaPowerToGF9 :: AlphaPower -> (Int, Int)
alphaPowerToGF9 A0 = (1, 0)
alphaPowerToGF9 A1 = (0, 1)
alphaPowerToGF9 A2 = (2, 0)
alphaPowerToGF9 A3 = (0, 2)

-- | GF(9) 域乘法：@(a+bα)(c+dα) = (ac − bd) + (ad + bc)α@，@α² = −1@。
-- 权威逐字：@(a , b) *gf9 (c , d) = ((a ⊗ c) ⊕ (negate (b ⊗ d))) , ((a ⊗ d) ⊕ (b ⊗ c))@
gf9Mul :: (Int, Int) -> (Int, Int) -> (Int, Int)
gf9Mul (a, b) (c, d) = ((a * c - b * d) `mod` 3, (a * d + b * c) `mod` 3)

-- | @mulAlpha@：C₄ 中的乘法。
--
-- 指数上就是 @(i+j) mod 4@（因 @C₄ ≅ Z/4@），但**这里以 GF(9) 域乘法为准**
-- ——两者一致这件事本身由 Spec 对拍验证（避免再次只证"结果相同"）。
mulAlpha :: AlphaPower -> AlphaPower -> AlphaPower
mulAlpha a b
  | gf9Mul (alphaPowerToGF9 a) (alphaPowerToGF9 b) == alphaPowerToGF9 A0 = A0
  | gf9Mul (alphaPowerToGF9 a) (alphaPowerToGF9 b) == alphaPowerToGF9 A1 = A1
  | gf9Mul (alphaPowerToGF9 a) (alphaPowerToGF9 b) == alphaPowerToGF9 A2 = A2
  | otherwise = A3

-- | @alphaInv@：(α^i)⁻¹ = α^{(−i) mod 4}（= @α^{4−i}@）。
alphaInv :: AlphaPower -> AlphaPower
alphaInv a = toEnum ((4 - fromEnum a) `mod` 4)

-- | @DuodecPoint@ = @Trit × AlphaPower@ —— 3 × 4 = 12 个元素。
type DuodecPoint = (Int, AlphaPower)

-- | @mixedOp@：第一分量 GF(3) 加法步进，第二分量 ⟨α⟩ 乘法旋转。
mixedOp :: DuodecPoint -> DuodecPoint -> DuodecPoint
mixedOp (x, a) (y, b) = ((x + y) `mod` 3, mulAlpha a b)

duodecE :: DuodecPoint
duodecE = (0, A0)

-- | CRT 重构 @Z/3 ⊕ Z/4 ≅ Z/12@：@x = (4a + 9b) mod 12@
-- （数值锚: math/cpp/tests/test_duodec_crt.cpp，144 分支同态 PASS）。
crt12 :: DuodecPoint -> Int
crt12 (x, a) = (4 * x + 9 * fromEnum a) `mod` 12

-- | @mixedOp^n@：右乘 e 共 n 次（即 p 的 n 次幂）。
mixedOpN :: Int -> DuodecPoint -> DuodecPoint
mixedOpN n p = iterate (mixedOp p) duodecE !! n

-- | 元素阶：最小的 n > 0 使 p^n = e。零冥族的相位归零周期即生成元的阶。
zeroOblivionPeriod :: DuodecPoint -> Int
zeroOblivionPeriod p = head [ n | n <- [1 ..], mixedOpN n p == duodecE ]

-- | 从 e 出发，逐层右乘 step，取前 60 层的 @crt12@ 轨迹。
-- 12 = lcm(3,4) 应当使轨迹周期为 12，而不是落进吸收态。
phaseTrajectory :: DuodecPoint -> Int -> [Int]
phaseTrajectory step layers = take layers [ crt12 (mixedOpN n step) | n <- [0 ..] ]

--------------------------------------------------------------------------------
-- GF(27) 载体 —— GF(3³) = GF(3)[x]/(x³+2x+1)
--
-- 参考 Sovereign.Algebra.GF27（Agda，0 postulate）:
--   GF27 = Trit × Trit × Trit，(a, b, c) = a + bα + cα²
--   alpha      = (T₀, T₁, T₀)   → 编码 3
--   alpha-sq   = (T₀, T₀, T₁)   → 编码 9
--   alpha-cubed : α·α·α ≡ (T₂, T₁, T₀) = α + 2   ← refl 证明
--   GF(27)* ≅ Z/26Z，生成元 α（阶 26，α¹³ = 2 = −1）
--
-- 用途：GF(3) 只有 3 个元素，装不下「音阶级数」Σtrits ∈ [0,12] —— 当 Σtrits ≡ 0
-- (mod 3) 时就被零因子抹平（dim=36 退化的根因）。GF(27) 有 27 个元素，
-- 恰好覆盖 [0,26]，且与嵌入层的「9 基球谐 → 27 维」同构。
--------------------------------------------------------------------------------

-- | 编码 @a + 3b + 9c ↔ a + bα + cα²@（0..26）。
gf27Decode :: Int -> (Int, Int, Int)
gf27Decode e = (e `mod` 3, (e `div` 3) `mod` 3, (e `div` 9) `mod` 3)

gf27Encode :: (Int, Int, Int) -> Int
gf27Encode (a, b, c) = (a `mod` 3) + 3 * (b `mod` 3) + 9 * (c `mod` 3)

-- | GF(27) 乘法（**参考实现**）。展开后用 @α³ = α + 2@（即 mod 3 下 @α³ = α − 1@）归约：
-- @α⁴ = α² − α@。
--
-- 保留它有两用：① 作为 'gf27MulTable' 的建表源；② 作为对拍基线。
gf27MulRef :: Int -> Int -> Int
gf27MulRef x y = gf27Encode (a, b, c)
  where
    (a1, b1, c1) = gf27Decode x
    (a2, b2, c2) = gf27Decode y
    c0 = a1 * a2                            -- 常数
    e1 = a1 * b2 + b1 * a2                  -- α
    e2 = a1 * c2 + b1 * b2 + c1 * a2        -- α²
    e3 = b1 * c2 + c1 * b2                  -- α³ → 折回 α 与常数
    e4 = c1 * c2                            -- α⁴ = α² − α
    a = c0 - e3                             -- α³ = α − 1：常数得 −1×e3
    b = e1 + e3 - e4
    c = e2 + e4

-- | 27×27 乘法表（顶层 CAF，只构建一次）。
--
-- ⚡ 动机：原实现每次乘法做 2×'gf27Decode' + 1×'gf27Encode' ——
-- 合计 **7 次除法**（`div`/`mod`）外加 2 个 `(Int,Int,Int)` 元组分配。
-- 全 60 层 ≈ 25M 次/层时，这才是 60 秒/层的主因（不是 thunk）。
-- 查表后每次乘法 = 1 次求址 + 1 次数组读：**0 除法、0 分配**。
gf27MulTable :: V.Vector Int
gf27MulTable = V.generate (27 * 27) (\i -> let (a, b) = i `divMod` 27 in gf27MulRef a b)

--------------------------------------------------------------------------------
-- GF(27) 的周期结构：离散对数（权威来源 Sovereign/Algebra/GF27.agda）
--
-- > GF27 = Trit × Trit × Trit                 -- (a,b,c) = a + bα + cα²
-- > _+gf27_ (a,b,c) (d,e,f) = (a⊕d,b⊕e,c⊕f)   -- 加法群 (Z/3)³，逐分量
-- > GF(27)* ≅ Z/26Z, 生成元 α (阶 26, α¹³ = 2 = −1)
-- > data GF27Star = pow0 … pow25               -- 26 个非零元素
-- > fromGF27 : GF27 → GF27Star                 -- 即 log 表
--
-- 于是 **乘法 = 指数相加 mod 26**（2 次表读 + 1 次加法），
-- 而非多项式乘（~10 次整数运算）。整数编码沿用 @a + 3b + 9c@（'gf27Encode'），
-- 是 (a,b,c) 的双射。
--------------------------------------------------------------------------------

-- | @pow k@ 的整数编码 @a + 3b + 9c@（对应 @(a,b,c) = α^k@）。
-- 由 GF27.agda 的 @toGF27 pow0 … pow25@ 逐项换算。
gf27PowEnc :: V.Vector Int
gf27PowEnc = V.fromList
  [ 1, 3, 9, 5, 15, 23, 13, 17, 20, 4, 12, 14, 11, 2, 6, 18
  , 7, 21, 16, 26, 22, 10, 8, 24, 25, 19 ]

-- | 整数编码 → log（0..25）；**零元记 −1**。
--
-- ⚠️ 与 Agda 的区别（务必注意，否则拿 Agda 对拍会「发现表错了」）：
--
--   Agda: @fromGF27 : GF27 → GF27Star@ —— 值域是 **26 个构造子**，不是 ℕ。
--   且 @fromGF27 (T₀,T₀,T₀) = pow0@，即**把零元折到单位元**（返回 0 号指数）。
--   GF27 有 27 个元素而 GF27* 只有 26 个，**27 → 26 必然不是单射** ——
--   撞在一起的就是 @0@ 与 @pow0@。所以「零元单列一个哨兵值」是**本实现层加的约定**，
--   Agda 并未给出；本表用 @-1@ 作哨兵。
gf27LogTable :: V.Vector Int
gf27LogTable = V.create $ do
  v <- MV.replicate 27 (-1)
  sequence_ [ MV.write v (gf27PowEnc V.! k) k | k <- [0 .. 25] ]
  pure v

-- | log → 整数编码。
gf27ExpTable :: V.Vector Int
gf27ExpTable = gf27PowEnc

--------------------------------------------------------------------------------
-- Frobenius 自同构 σ(x) = x³ —— **两个坐标系，矢量版为语义权威**
--
-- Agda 权威（Sovereign/Algebra/GF27.agda §5b）：
--   @frobenius (a,b,c) = ((a ⊕ negate b) ⊕ c, b ⊕ c, c)@
-- 它是 **GF(3)-线性的**（@frobenius-add@ 保加法，@frobenius-scalar@ 保标量乘），
-- 阶为 3（@frobenius³-id@）。这是**矢量坐标系**里的形态。
--
-- ⚠️ 而 @log/exp@ 是**乘法群** @GF(27)* ≅ Z/26@ 的坐标系，在那里 σ 写成
-- @×3 mod 26@ —— **结果相同，但不再是 GF(3)-线性映射**（log 不保加法）。
-- 二者不可互换：**要线性/要保加法，只能用矢量版**。
--
-- 本模块把**矢量版作语义权威**，标量版仅作等价性佐证（有对拍）。
--------------------------------------------------------------------------------

-- | Frobenius @σ(x) = x³@（**矢量版**，语义权威）。
-- @σ(a,b,c) = ((a ⊕ ¬b) ⊕ c, b ⊕ c, c)@，逐分量，保加法与标量乘。
gf27FrobeniusVec :: Int -> Int
gf27FrobeniusVec x =
  let (a, b, c) = gf27Decode x
      nb = (3 - b) `mod` 3
  in gf27Encode (((a + nb) + c) `mod` 3, (b + c) `mod` 3, c)

-- | Frobenius 的**标量（指数）形式**：@σ(x) ↦ exp[(3·log x) mod 26]@。
--
-- ⚠️ 它不是**实现**，而是**佐证**：与 'gf27FrobeniusVec' 逐点相等这件事，
-- 说明 @log/exp@ 表确实是 @GF(27)* ≅ Z/26@ 的正确同构（**表的性质**，
-- 不是「乘法实现蕴含它」）。
-- ⚠️ @x = 0@ 是唯一例外：@log 0 = -1@，@3·(-1) mod 26 ≠ -1@，故必须分支。
gf27FrobeniusLog :: Int -> Int
gf27FrobeniusLog x =
  let lx = gf27LogTable V.! (x `mod` 27)
  in if lx < 0 then 0 else gf27ExpTable V.! ((3 * lx) `mod` 26)

-- | 周期乘法：@x ⊗ y = α^((log x + log y) mod 26)@（任一为 0 则 0）。
gf27MulCyclic :: Int -> Int -> Int
gf27MulCyclic x y
  | lx < 0 || ly < 0 = 0
  | otherwise        = gf27ExpTable V.! ((lx + ly) `mod` 26)
  where
    lx = gf27LogTable V.! (x `mod` 27)
    ly = gf27LogTable V.! (y `mod` 27)

-- | GF(27) 乘法（**热路径实现**）。
--
-- ⚠️ 选型依据（2026-09-12 benchmark，见 Spec 的 L1/L2）：
--
-- | 实现 | L1 孤立 (10^6) | L2 顺序模式 (1440 维点积×300) |
-- |---|---|---|
-- | 'gf27MulRef'（多项式乘）| 232.26 ms | 0.4241 ms |
-- | 'gf27MulTable'（27×27 表）| **26.30 ms** | **0.0316 ms** ← 最快 |
-- | 'gf27MulCyclic'（log/exp）| 68.08 ms | 0.0998 ms（3.16× 于表版）|
--
-- 周期版虽然数学上更漂亮（@GF(27)* ≅ Z/26@），但每次乘法要 3 次表访问
-- （@mod 27@ ×2 + @mod 26@ + 2 次 'VU.!'），而表版只需 1 次求址 + 1 次读。
-- @-ddump-simpl@ 显示 'gf27MulCyclic' 的 3 次 'VU.!' 各带一次 @checkError Bounds@
-- 边界检查；'gf27MulTable' 只有 1 次。故**热路径用表版**。
--
-- 'gf27MulCyclic' 保留作**诊断/数学验证**工具（周期结构本身有效，已由 729 组对拍证实）。
gf27Mul :: Int -> Int -> Int
gf27Mul x y = gf27MulTable V.! (x * 27 + y)
