{-# LANGUAGE GeneralizedNewtypeDeriving #-}

-- | 严格类型层：**让类型系统阻止范畴混淆**。
--
-- 本模块的存在理由（2026-09-12 审计）：此前六种不同范畴的数学对象
-- 全部用裸 'Int' 承载，导致反复出现「把 GF(27) 元素当整数序号」
-- 「把权重 trit 当 GF(27) 元素」「把 C₄ 当 Z/4 加法」这类错误。
--
-- 这里为每个范畴定义**独立类型**，构造子**不导出**，只走 smart constructor，
-- 使不变量（值域）由构造保证，混淆在编译期就被拒绝。
--
-- 范畴清单（互不可换）：
--
-- > Trit        GF(3) 的元素        值域 [0,2]        加法/乘法都在 GF(3)
-- > GF9         GF(3²) = GF(3)[α]/(α²+1) 的元素        (a,b) = a + bα
-- > GF27        GF(3³) = (Z/3)³ 加  ⊕  乘法群 ≅ Z/26   值域 [0,26]
-- > Z3r         Z/3¹¹ 环的元素（3 ≠ 0！不是域）         值域 [0, 3¹¹)
-- > Harmonic   谐波指数（相位周次），**不是元素值**       值域 ℕ
--
-- ⚠️ 特别注意 @GF27@ 的两重结构（不可只取其一）：
--   * 加法群 @(Z/3)³@ —— 逐分量，见 'plusGF27'
--   * 乘法群 ≅ @Z/26@ —— 周期，见 'mulGF27'
--   两者是**同一集合上的两个运算**，不是两种表示。
module Infrastructure.CPU.SovereignTypes
  ( -- * GF(3) 的元素
    Trit
  , mkTrit
  , tritToInt
  , plusTrit
  , mulTrit
  , negTrit
    -- * GF(3²) = GF(9) 的元素
  , GF9
  , mkGF9
  , gf9ToPair
  , plusGF9
  , mulGF9
  , gf9One
  , gf9Zero
    -- * GF(3³) = GF(27) 的元素
  , GF27
  , mkGF27
  , gf27ToInt
  , gf27PowEnc
  , gf27LogTable
  , plusGF27
  , mulGF27
  , negGF27
  , gf27Zero
  , gf27One
  , embedGF3
  , projectGF3
  , dotGF27
  , matmulGF27
  , rmsNormGF27
  , alphaPowGF27
  , swiGLUGF27
  , toGF27Vec
  , toGF27Mat
  , fromGF27Vec
  , fromGF27Mat
  , toTritVec
  , toTritMat
  , fromTritVec
  , fromTritMat
    -- * Z/3¹¹ 环的元素（3 ≠ 0）
  , Z3r
  , mkZ3r
  , z3rToInt
  , plusZ3r
  , z3rModulus
    -- * 谐波指数（相位周次，不是元素值）
  , Harmonic
  , mkHarmonic
  , harmonicToInt
  ) where


--------------------------------------------------------------------------------
-- GF(3)：特征 3 的素域
--------------------------------------------------------------------------------

-- | @GF(3)@ 的元素。值域 @[0,2]@；@1+1+1 = 0@（特征 3）。
newtype Trit = Trit Int
  deriving (Eq, Ord, Show)

-- | 唯一入口：构造时即归一化到 @[0,2]@。
mkTrit :: Int -> Trit
mkTrit x = Trit (x `mod` 3)

tritToInt :: Trit -> Int
tritToInt (Trit x) = x

plusTrit :: Trit -> Trit -> Trit
plusTrit (Trit a) (Trit b) = Trit ((a + b) `mod` 3)

mulTrit :: Trit -> Trit -> Trit
mulTrit (Trit a) (Trit b) = Trit ((a * b) `mod` 3)

negTrit :: Trit -> Trit
negTrit (Trit a) = Trit ((3 - a) `mod` 3)

--------------------------------------------------------------------------------
-- GF(9) = GF(3)[α]/(α²+1)
--------------------------------------------------------------------------------

-- | @GF(9)@ 的元素 @(a,b) = a + bα@，@α² = −1@。
--
-- 权威：@Sovereign/Algebra/GF9.agda@ —— @GF9 = GF3 × GF3@。
-- 乘法群 @GF(9)* ≅ C₈@；其 @C₄@ 子群 @{1,α,α²,α³}@ 由 @α@（阶 4）生成。
newtype GF9 = GF9 (Int, Int)
  deriving (Eq, Ord, Show)

-- | 构造时归一化两个分量到 @[0,2]@。
mkGF9 :: (Int, Int) -> GF9
mkGF9 (a, b) = GF9 (a `mod` 3, b `mod` 3)

gf9ToPair :: GF9 -> (Int, Int)
gf9ToPair (GF9 p) = p

plusGF9 :: GF9 -> GF9 -> GF9
plusGF9 (GF9 (a, b)) (GF9 (c, d)) = GF9 ((a + c) `mod` 3, (b + d) `mod` 3)

-- | @(a+bα)(c+dα) = (ac − bd) + (ad + bc)α@（因 @α² = −1@）。
-- 权威逐字：@(a , b) *gf9 (c , d) = ((a ⊗ c) ⊕ (negate (b ⊗ d))) , ((a ⊗ d) ⊕ (b ⊗ c))@
mulGF9 :: GF9 -> GF9 -> GF9
mulGF9 (GF9 (a, b)) (GF9 (c, d)) =
  GF9 ((a * c - b * d) `mod` 3, (a * d + b * c) `mod` 3)

gf9Zero :: GF9
gf9Zero = GF9 (0, 0)

gf9One :: GF9
gf9One = GF9 (1, 0)

--------------------------------------------------------------------------------
-- GF(27) = GF(3³)
--------------------------------------------------------------------------------

-- | @GF(27)@ 的元素，整数编码 @a + 3b + 9c ↔ a + bα + cα²@，值域 @[0,26]@。
--
-- ⚠️ 这个类型承载**两个运算**，不可只认其一：
--
-- > 加法群 (Z/3)³   —— 'plusGF27'，逐分量
-- > 乘法群 ≅ Z/26Z  —— 'mulGF27'，周期（生成元 α 阶 26，α¹³ = −1）
--
-- 权威：@Sovereign/Algebra/GF27.agda@。
newtype GF27 = GF27 Int
  deriving (Eq, Ord, Show)

-- | 构造时归一化到 @[0,26]@。
mkGF27 :: Int -> GF27
mkGF27 x = GF27 (x `mod` 27)

gf27ToInt :: GF27 -> Int
gf27ToInt (GF27 x) = x

-- | 加法：@(Z/3)³@ 逐分量 —— **矢量结构**（这是 GF(27) 的加法群）。
plusGF27 :: GF27 -> GF27 -> GF27
plusGF27 (GF27 x) (GF27 y) = GF27 (gf27AddRaw x y)
  where
    dec e = (e `mod` 3, (e `div` 3) `mod` 3, (e `div` 9) `mod` 3)
    enc (a, b, c) = (a `mod` 3) + 3 * (b `mod` 3) + 9 * (c `mod` 3)
    gf27AddRaw p q =
      let (a1, b1, c1) = dec p
          (a2, b2, c2) = dec q
      in enc ((a1 + a2) `mod` 3, (b1 + b2) `mod` 3, (c1 + c2) `mod` 3)

-- | @α^k@ 的整数编码 @a+3b+9c@（权威 @GF27.agda@ 的 @toGF27 pow0…pow25@ 逐项换算）。
gf27PowEnc :: [Int]
gf27PowEnc = [ 1, 3, 9, 5, 15, 23, 13, 17, 20, 4, 12, 14
             , 11, 2, 6, 18, 7, 21, 16, 26, 22, 10, 8, 24, 25, 19 ]

-- | 元素编码 → log（0..25）；**零元记 −1**（本实现层加的约定）。
--
-- ⚠️ 与 Agda 的 @fromGF27@ 不同：那边值域是 26 个构造子，且**把零元折到 pow0**
-- （返回 0 号指数，不是哨兵）。GF27 有 27 个元素而 GF27* 只有 26 个，
-- 27 → 26 必然不是单射，撞在一起的就是 @0@ 与 @pow0@。
gf27LogTable :: [Int]
gf27LogTable = [ pick e | e <- [0 .. 26] ]
  where
    pick e = case [ k | (k, v) <- zip [0 ..] gf27PowEnc, v == e ] of
               (k : _) -> k
               []      -> -1

-- | 乘法：@GF(27)* ≅ Z/26@ 的周期形式，@x⊗y = α^((log x + log y) mod 26)@。
--
-- ⚠️ 刻意用**周期**形式而非多项式乘：两者结果相同（729 组对拍），
-- 但周期形式**显式暴露乘法群结构**，避免「把 α 当 α²」这类范畴错误。
mulGF27 :: GF27 -> GF27 -> GF27
mulGF27 (GF27 x) (GF27 y) = GF27 $
  let lp = gf27LogTable !! x
      lq = gf27LogTable !! y
  in if lp < 0 || lq < 0 then 0 else gf27PowEnc !! ((lp + lq) `mod` 26)

-- | 加法逆元：逐分量取负（@(Z/3)³@ 里）。
negGF27 :: GF27 -> GF27
negGF27 (GF27 x) = GF27 (enc (neg3 a, neg3 b, neg3 c))
  where
    (a, b, c) = (x `mod` 3, (x `div` 3) `mod` 3, (x `div` 9) `mod` 3)
    neg3 v = (3 - v) `mod` 3
    enc (p, q, r) = p + 3 * q + 9 * r

gf27Zero :: GF27
gf27Zero = GF27 0

gf27One :: GF27
gf27One = GF27 1

-- | GF(3) 嵌入 GF(27)：@a ↦ a + 0α + 0α²@。
--
-- 权威：@GF27.agda@ 的 @embed-gf3-gf27 a = a , T₀ , T₀@。
-- 这是**权重（Trit）进入 GF(27) 运算的唯一合法通道** —— 权重是 GF(3) 元素，
-- 激活是 GF(27) 元素，两者不能直接相乘，必须先嵌入。
embedGF3 :: Trit -> GF27
embedGF3 (Trit a) = GF27 (a `mod` 3)

-- | 反向：GF(27) 元素若落在嵌入像里（b = c = 0）则取出其 GF(3) 分量。
projectGF3 :: GF27 -> Maybe Trit
projectGF3 (GF27 x) =
  let (a, b, c) = (x `mod` 3, (x `div` 3) `mod` 3, (x `div` 9) `mod` 3)
  in if b == 0 && c == 0 then Just (Trit a) else Nothing

--------------------------------------------------------------------------------
-- 类型化的向量/矩阵运算
--
-- 这些是**迁移目标**：签名里只有 'GF27'，任何把 trit / Z3r / 整数序号
-- 混进来的写法都会在编译期被拒绝。与 'Infrastructure.CPU.SovereignGF27'
-- 的 @Int@ 版逐元素等价（对拍见 Spec）。
--------------------------------------------------------------------------------

-- | 类型化点积：@Σ_j (embed(w_j) ⊗ x_j)@。
--
-- ⚠️ 范畴：@w@ 是**权重**（GF(3) 元素 'Trit'），@x@ 是**激活**（GF(27) 元素）。
-- 两者不同范畴，必须经 'embedGF3' 提升后才能相乘（对应 Agda 的 @embed-gf3-gf27@）。
-- 加法走 @(Z/3)³@ 逐分量（'plusGF27'）。
dotGF27 :: [Trit] -> [GF27] -> GF27
dotGF27 = go gf27Zero
  where
    go acc (a : as) (b : bs) = go (plusGF27 acc (mulGF27 (embedGF3 a) b)) as bs
    go acc _        _        = acc

-- | 类型化 matmul：@w@ 为 @rows × cols@ 的**权重矩阵**（'Trit'），@x@ 为激活（'GF27'）。
matmulGF27 :: [[Trit]] -> [GF27] -> [GF27]
matmulGF27 w x = [ dotGF27 row x | row <- w ]

-- | 类型化归一化（**逐分量**语义，与 @gf27RmsNorm@ 一致）：
-- @x_j ↦ (x_j ⊗ γ_j) ⊗ α^[x_j ≠ 0]@。
--
-- 旋转步数由**该分量自身**决定，而不是全向量的非零计数 —— 后者会把
-- 矢量塌缩成一个标量（见 @gf27RmsNormScalar@ 的注记）。
-- @α^k@ 用 'alphaPowGF27'（周期形式）。
rmsNormGF27 :: [GF27] -> [GF27] -> [GF27]
rmsNormGF27 gamma x =
  [ mulGF27 (mulGF27 xj (gamma !! (j `mod` length gamma)))
            (alphaPowGF27 (if xj == gf27Zero then 0 else 1))
  | (j, xj) <- zip [0 ..] x ]

-- | @α^k@（周期形式）：@α^k = exp[(k · 1) mod 26]@，即 @α@ 的 @k@ 次幂。
-- 用 'gf27PowEnc' 直接取表，避免逐次乘法。
alphaPowGF27 :: Int -> GF27
alphaPowGF27 k = GF27 (gf27PowEnc !! (k `mod` 26))

-- | 类型化 SwiGLU（**逐分量门控**）：@gated_j = g_j ⊗ u_j@。
swiGLUGF27 :: [[Trit]] -> [[Trit]] -> [[Trit]] -> [GF27] -> [GF27]
swiGLUGF27 gateW upW downW x = matmulGF27 downW gated
  where
    g = matmulGF27 gateW x
    u = matmulGF27 upW x
    gated = zipWith mulGF27 g u

--------------------------------------------------------------------------------
-- 与 @Int@ 版的双向转换（仅用于边界，不在内核里来回转）
--------------------------------------------------------------------------------

-- | @[Int] → [GF27]@（值先归一化到 [0,26]）。
toGF27Vec :: [Int] -> [GF27]
toGF27Vec = map mkGF27

-- | @[[Int]] → [[GF27]]@。
toGF27Mat :: [[Int]] -> [[GF27]]
toGF27Mat = map toGF27Vec

fromGF27Vec :: [GF27] -> [Int]
fromGF27Vec = map gf27ToInt

fromGF27Mat :: [[GF27]] -> [[Int]]
fromGF27Mat = map fromGF27Vec

-- | @[Int] → [Trit]@（**权重**用，值归一化到 [0,2]）。
toTritVec :: [Int] -> [Trit]
toTritVec = map mkTrit

-- | @[[Int]] → [[Trit]]@（**权重矩阵**用）。
toTritMat :: [[Int]] -> [[Trit]]
toTritMat = map toTritVec

fromTritVec :: [Trit] -> [Int]
fromTritVec = map tritToInt

fromTritMat :: [[Trit]] -> [[Int]]
fromTritMat = map fromTritVec

--------------------------------------------------------------------------------
-- Z/3¹¹：环，**不是**域
--------------------------------------------------------------------------------

-- | @Z/3¹¹@ 的元素。注意 **3 ≠ 0**（与 GF(3)/GF(9)/GF(27) 根本不同）。
newtype Z3r = Z3r Int
  deriving (Eq, Ord, Show)

z3rModulus :: Int
z3rModulus = 177147   -- 3¹¹

mkZ3r :: Int -> Z3r
mkZ3r x = Z3r (x `mod` z3rModulus)

z3rToInt :: Z3r -> Int
z3rToInt (Z3r x) = x

plusZ3r :: Z3r -> Z3r -> Z3r
plusZ3r (Z3r a) (Z3r b) = Z3r ((a + b) `mod` z3rModulus)

--------------------------------------------------------------------------------
-- 谐波指数：相位周次，**不是元素值**
--------------------------------------------------------------------------------

-- | 谐波指数（相位周次）。@TriadicHarmonic.agda@ 里 @0²/0⁶/0¹⁰@ 的那个指数
-- —— 「0 的指数是旋转相位标记，不是算术上标」。
--
-- ⚠️ 它与 'GF27' / 'GF9' 的元素**不同范畴**：指数是 @ℕ@，元素是域元素。
-- 混用就会得出「α^2 = α^6」这类错误（正确关系是 @α² = α⁶ = α¹⁰ = −1@ 仅在
-- @C₄@ 相位上相等，指数本身各有周次语义）。
newtype Harmonic = Harmonic Int
  deriving (Eq, Ord, Show)

mkHarmonic :: Int -> Harmonic
mkHarmonic = Harmonic . abs

harmonicToInt :: Harmonic -> Int
harmonicToInt (Harmonic n) = n
