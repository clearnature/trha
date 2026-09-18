{-# LANGUAGE ForeignFunctionInterface #-}

-- | GF(27) 行点积的 AVX2 入口（含运行时检测与标量回退）。
--
-- ⚠️ **目的不是提速，而是给 GF(27) 的代数结构提供第 4 个独立实现**（Haskell 标量 /
-- C 标量 / 本模块 AVX2 / GPU WGSL），四者逐元素全等才说明结构在异构实现下一致。
-- **性能不作判据**：本机实测 AVX2 反而略慢于标量，但那不影响其验证价值。
-- 判据见 @docs\/plans\/verification-criteria.md@。
--
-- C 层见 @cbits\/gf27_avx2.c@。**数学约定只在 Haskell 侧定义**：
-- log\/exp 表来自 'Infrastructure.CPU.GF3Intrinsic' 的 'gf27LogTable' \/
-- 'gf27ExpTable'，本模块把它们转成 @int32@ 数组传给 C —— C 里不重复定义数学关系，
-- 避免两处漂移。
--
-- 为什么独立成模块而不是直接改 'gf27Matmul'：后者在**真链**上
-- （@SovereignGF27@ → … → @LLM.Adapter.Interface@ 的 CPU adapter）。先用本模块把
-- "SIMD ≡ 标量" 对拍做扎实，接线是之后单独的一步。
module Infrastructure.CPU.GF27SIMD
  ( hasAVX2
  , gf27Rowdot
  , gf27RowdotScalarOnly
  , gf27MatmulC
  , gf27MatmulCTable
  , gf27MatmulCTableVec
  ) where

import Data.Int (Int32)
import qualified Data.Vector.Storable as VS
import qualified Data.Vector.Unboxed as VU
import Foreign.C.Types (CInt (..), CLLong (..))
import Foreign.Marshal.Array (withArray, peekArray, allocaArray)
import Foreign.Ptr (Ptr)
import Foreign.Storable (peekElemOff)

import Infrastructure.CPU.GF3Intrinsic (gf27ExpTable, gf27LogTable)

-- | 本机是否可用 AVX2（C 层用 @__builtin_cpu_supports@ 判定）。
foreign import ccall unsafe "trha_gf27_has_avx2"
  cHasAVX2 :: IO CInt

-- | 按运行时能力派发的行点积（有 AVX2 走 AVX2，否则标量）。
foreign import ccall unsafe "trha_gf27_rowdot"
  cRowdot :: Ptr Int32 -> Ptr Int32 -> CLLong -> Ptr Int32 -> Ptr Int32 -> IO Int32

-- | 强制标量路径（供"AVX2 ≡ 标量"对拍）。
foreign import ccall unsafe "trha_gf27_rowdot_scalar_only"
  cRowdotScalar :: Ptr Int32 -> Ptr Int32 -> CLLong -> Ptr Int32 -> Ptr Int32 -> IO Int32

-- | **整块矩阵乘**：一次 C 调用算 [rows×cols] 权重 × [cols] 激活 → [rows]。
-- 绕开逐行 FFI 的边界/拷贝开销（每行 81µs 中 FFI 是大头）。
foreign import ccall unsafe "trha_gf27_matmul"
  cMatmul :: Ptr Int32 -> Ptr Int32 -> Ptr Int32 -> CInt -> CInt
          -> Ptr Int32 -> Ptr Int32 -> IO CInt

-- | 方向 A：27×27 连续乘积表版（每乘 1 次连续访存替代 6-gather）。
foreign import ccall unsafe "trha_gf27_matmul_table"
  cMatmulTable :: Ptr Int32 -> Ptr Int32 -> Ptr Int32 -> CInt -> CInt
               -> Ptr Int32 -> Ptr Int32 -> IO CInt

-- | log\/exp 表的 @int32@ 副本（表很小，仅 27 项；每次调用重建的代价可忽略，
-- 换成顶层常量会引入 @unsafePerformIO@，不值得）。
logT32, expT32 :: [Int32]
logT32 = map fromIntegral (VU.toList gf27LogTable)
expT32 = map fromIntegral (VU.toList gf27ExpTable)

-- | 本机是否可用 AVX2。
hasAVX2 :: IO Bool
hasAVX2 = (/= 0) <$> cHasAVX2

-- | 计算 @Σ_j w[j] ⊗ x[j]@（GF(27) 行点积），按运行时能力选路径。
gf27Rowdot :: [Int] -> [Int] -> IO Int
gf27Rowdot ws xs = runRowdot cRowdot ws xs

-- | 同上，但强制标量（用于对拍）。
gf27RowdotScalarOnly :: [Int] -> [Int] -> IO Int
gf27RowdotScalarOnly ws xs = runRowdot cRowdotScalar ws xs

runRowdot
  :: (Ptr Int32 -> Ptr Int32 -> CLLong -> Ptr Int32 -> Ptr Int32 -> IO Int32)
  -> [Int]
  -> [Int]
  -> IO Int
runRowdot fn ws xs =
  withArray (map fromIntegral ws) $ \wp ->
    withArray (map fromIntegral xs) $ \xp ->
      withArray logT32 $ \lp ->
        withArray expT32 $ \ep ->
          fromIntegral <$> fn wp xp (fromIntegral (length ws)) lp ep

-- | 整块矩阵乘：@rows@ × @cols@ 行优先权重 @w@ × 激活 @x@ ⇒ 结果 @rows@。
-- 与 'gf27Rowdot' 同一数学（逐行同构），但一次 C 调用算完整个矩阵，
-- 把 FFI 边界/拷贝开销摊销到 @rows@ 行。
--
-- ⚠️ 长度契约：@w@ 长度必须 ≥ @rows×cols@，@x@ 长度 ≥ @cols@，否则 C 侧越界读。
-- 这是内部接口，调用方（层前向）保证形状；测试里先行断言长度。
gf27MatmulC
  :: Int              -- ^ rows
  -> Int              -- ^ cols
  -> [Int]            -- ^ 权重（行优先，扁平）
  -> [Int]            -- ^ 激活（长度 ≥ cols；多余忽略）
  -> IO [Int]
gf27MatmulC rows cols w x =
  withArray (map fromIntegral w) $ \wp ->
    withArray (map fromIntegral x) $ \xp ->
      withArray logT32 $ \lp ->
        withArray expT32 $ \ep ->
          allocaArray rows $ \outp -> do
            rc <- cMatmul outp wp xp (fromIntegral rows) (fromIntegral cols) lp ep
            if rc /= 0
              then ioError (userError ("gf27MatmulC: C 侧返回错误码 " ++ show rc))
              else map fromIntegral <$> peekArray rows outp

-- | 同 'gf27MatmulC'，但走 27×27 连续乘积表（每乘 1 次连续访存）。
-- 数学等价（同一 logT/expT 展开），应显著快于 gather 版。
gf27MatmulCTable
  :: Int              -- ^ rows
  -> Int              -- ^ cols
  -> [Int]            -- ^ 权重（行优先，扁平；元素 ∈ {0,1,2}）
  -> [Int]            -- ^ 激活（长度 ≥ cols；元素 ∈ {0..26}）
  -> IO [Int]
gf27MatmulCTable rows cols w x =
  withArray (map fromIntegral w) $ \wp ->
    withArray (map fromIntegral x) $ \xp ->
      withArray logT32 $ \lp ->
        withArray expT32 $ \ep ->
          allocaArray rows $ \outp -> do
            rc <- cMatmulTable outp wp xp (fromIntegral rows) (fromIntegral cols) lp ep
            if rc /= 0
              then ioError (userError ("gf27MatmulCTable: C 侧返回错误码 " ++ show rc))
              else map fromIntegral <$> peekArray rows outp

-- | **指针版**：权重/激活已是 @VU.Vector Int32@（调用方预构造、常驻内存），
-- FFI 只传指针，**不再每轮 fromIntegral + 拷贝 622 万元素**（那是隐藏的序列化
-- 串行点，实测吞掉 OpenMP 并行收益，见 journal j-mu5z7x46-ou6z）。
-- ⚠️ 输出仍是每轮 peekArray rows（结果量级 = rows ≤ 4320，可接受）。
-- ⚠️ 数学约定与 'gf27MatmulCTable' 完全一致（同一 C 入口，同一 logT/expT）。
gf27MatmulCTableVec
  :: Int              -- ^ rows
  -> Int              -- ^ cols
  -> VS.Vector Int32  -- ^ 权重（行优先，扁平；元素 ∈ {0,1,2}）
  -> VS.Vector Int32  -- ^ 激活（长度 ≥ cols；元素 ∈ {0..26}）
  -> IO (VS.Vector Int32)
gf27MatmulCTableVec rows cols w x =
  VS.unsafeWith w $ \wp ->
    VS.unsafeWith x $ \xp ->
      withArray logT32 $ \lp ->
        withArray expT32 $ \ep ->
          allocaArray rows $ \outp -> do
            rc <- cMatmulTable outp wp xp (fromIntegral rows) (fromIntegral cols) lp ep
            if rc /= 0
              then ioError (userError ("gf27MatmulCTableVec: C 侧返回错误码 " ++ show rc))
              else VS.generateM rows (peekElemOff outp)
