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
  ) where

import Data.Int (Int32)
import qualified Data.Vector.Unboxed as VU
import Foreign.C.Types (CInt (..), CLLong (..))
import Foreign.Marshal.Array (withArray)
import Foreign.Ptr (Ptr)

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
