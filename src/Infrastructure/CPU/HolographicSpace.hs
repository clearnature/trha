-- | 全息态与基模 —— 信息论闭包的类型基础设施（GF(9) 上的内积空间）。
--
-- 照 Agda 权威逐字实现：
--
-- > -- Sovereign.Analysis.FiniteInnerProduct
-- > VectorSpace n      = Fin n → GF9
-- > gf9-zero           = T₀ , T₀
-- > hermitianIP n f g  = sumGF9 n (λ i → f i *gf9 galoisConjugate (g i))
-- > normSq n f        = hermitianIP n f f
-- > basisVec           = λ i j → (i == j ? gf9-one : gf9-zero)
-- > basis-orthogonal  : ¬ (toℕ i ≡ toℕ j) → hermitianIP n (basisVec n i) (basisVec n j) ≡ gf9-zero
-- >
-- > -- Sovereign.Algebra.GF9
-- > galoisConjugate (a , b) = a , negate b          -- σ 是**对合**（galoisConjugate² = id）
-- > galoisNorm      (a , b) = (a ⊗ a) ⊕ (b ⊗ b)     -- a² + b²
-- > galoisFixedPoint : σ x ≡ x → Σ GF3 (λ a → x ≡ (a , T₀))   -- 不动点 ⟺ b = 0
-- >
-- > -- Sovereign.Structology.HolographicSpace
-- > BasisMode  = (vector : VectorSpace n) × (normSq n vector ≡ gf9-one)
-- > Orthogonal b₁ b₂ = hermitianIP _ (vector b₁) (vector b₂) ≡ gf9-zero
-- > basisAt n i = mkBasis (basisVec n i) (normSq-basisVec n i)
-- > basisAt-self : ∀ n i → vector (basisAt n i) i ≡ gf9-one
--
-- == 关键约定（容易写反，故显式记录）
--
-- 共轭加在 'hermitianIP' 的**第二个**参数上：@⟨f,g⟩ = Σ_i f_i ⊗ σ(g_i)@。
-- 这正是权威 'hermitian-linearˡ'（首参线性）与 'hermitian-conj-sym'（共轭对称）成立的
-- 方向；把 σ 挪到第一个参数会得到另一套内积。
--
-- == 判据
--
-- 这是 C1「代数结构 ↔ 权威规范」的一部分：本模块的每个定义都能在权威文件里找到逐字
-- 对应，对拍见 @test-cpu/Spec.hs@ 的 C1 · HolographicSpace 一节。
module Infrastructure.CPU.HolographicSpace
  ( -- * 向量空间
    VectorSpace
  , zeroVec
    -- * 共轭与范数（照 GF9.agda）
  , galoisConjugate
  , galoisNorm
    -- * 内积
  , hermitianIP
  , normSq
    -- * 标准基与基模
  , basisVec
  , basisAt
  , isOrthogonal
    -- * 宪法常量（照 HolographicSpace.agda）
  , infoDim
  , nCells
  , nOrbits
  , gOrder
  ) where

import Infrastructure.CPU.SovereignTypes (GF9, gf9One, gf9Zero, gf9ToPair, mkGF9, plusGF9, mulGF9)

--------------------------------------------------------------------------------
-- 向量空间
--------------------------------------------------------------------------------

-- | @VectorSpace n = Fin n → GF9@（权威）。
-- Haskell 里用**长度为 n 的列表**表示，顺序即下标。
type VectorSpace = [GF9]

-- | @zeroVec n _ = gf9-zero@（权威）。
zeroVec :: Int -> VectorSpace
zeroVec n = replicate n gf9Zero

--------------------------------------------------------------------------------
-- 共轭与范数（照 Sovereign.Algebra.GF9）
--------------------------------------------------------------------------------

-- | 伽罗瓦共轭 @σ@：@(a, b) ↦ (a, −b)@。
--
-- 权威：@galoisConjugate (a , b) = a , negate b@。
-- 注意 @mod 3@ 把 Haskell 的负数取模归一化到 @[0,2]@（如 @−1 ↦ 2@）。
galoisConjugate :: GF9 -> GF9
galoisConjugate x = let (a, b) = gf9ToPair x in mkGF9 (a, negate b)

-- | 伽罗瓦范数 @N(a, b) = a² + b²@（值在 GF(3) 里）。
--
-- 权威：@galoisNorm (a , b) = (a ⊗ a) ⊕ (b ⊗ b)@。
-- 它是不变式：@galoisNorm-conjugate : N (σ x) ≡ N x@。
galoisNorm :: GF9 -> Int
galoisNorm x = let (a, b) = gf9ToPair x in (a * a + b * b) `mod` 3

--------------------------------------------------------------------------------
-- 内积
--------------------------------------------------------------------------------

-- | 赫米特内积 @⟨f,g⟩ = Σ_i f_i ⊗ σ(g_i)@（权威）。
--
-- ⚠️ 共轭在**第二个**参数上 —— 权威 'hermitian-conj-sym'（共轭对称）与
-- 'hermitian-linearˡ'（首参线性）都是在这个方向下证明的。
hermitianIP :: VectorSpace -> VectorSpace -> GF9
hermitianIP f g = foldl plusGF9 gf9Zero (zipWith step f g)
  where
    step fi gi = mulGF9 fi (galoisConjugate gi)

-- | 平方范数 @‖f‖² = ⟨f,f⟩@（权威 @normSq n f = hermitianIP n f f@）。
normSq :: VectorSpace -> GF9
normSq f = hermitianIP f f

--------------------------------------------------------------------------------
-- 标准基与基模
--------------------------------------------------------------------------------

-- | 标准基向量 @basisVec n i@：第 @i@ 个位置是 @gf9-one@，其余为 @gf9-zero@。
--
-- 权威用递归定义（@suc@/@Fin.zero@ 分四种情形），展开后即"对角为 1、其余为 0"。
basisVec :: Int -> Int -> VectorSpace
basisVec n i = [ if j == i then gf9One else gf9Zero | j <- [0 .. n - 1] ]

-- | 基模 @basisAt n i = (basisVec n i, normSq-basisVec n i)@（权威）。
--
-- 权威把范数等于一作为**类型的字段**（@BasisMode.normOne : normSq n vector ≡ gf9-one@）；
-- Haskell 里做成一个可检验的二元组，对拍时断言第二个分量确实等于 @gf9-one@。
basisAt :: Int -> Int -> (VectorSpace, GF9)
basisAt n i = (basisVec n i, normSq (basisVec n i))

-- | 正交判定 @Orthogonal b₁ b₂ = ⟨b₁, b₂⟩ ≡ gf9-zero@（权威）。
isOrthogonal :: VectorSpace -> VectorSpace -> Bool
isOrthogonal b1 b2 = hermitianIP b1 b2 == gf9Zero

--------------------------------------------------------------------------------
-- 宪法常量（照 Sovereign.Structology.HolographicSpace 的 ℕ 级常量）
--------------------------------------------------------------------------------

-- | @INFO-DIM = 4320@（信息维数）。
infoDim :: Int
infoDim = 4320

-- | @N-CELLS = 729 = 3⁶@（格胞数）。
nCells :: Int
nCells = 729

-- | @N-ORBITS = 14@（轨道数，与 BurnsideT6 的 orbit-sizes-sum-729 一致）。
nOrbits :: Int
nOrbits = 14

-- | @G-ORDER = 54@（群阶）。
gOrder :: Int
gOrder = 54
