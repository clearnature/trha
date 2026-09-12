{-# LANGUAGE BangPatterns #-}

-- | 打包表示（5 trit/字节）—— 与 @.sov@ 的 @data\/N@ **同构**。
--
-- 动机（2026-09-12 实测）：全 60 层前向跑通但 GC 占 37%、累计分配 417 GB，
-- 根因是 @[[Int]]@ 表示（16 B\/元素，而信息量只有 0.2 B\/元素）。
-- 本模块给出紧凑表示：**1 字节存 5 个 trit**，与 checkpoint 字节流一致，
-- 于是权重可以直接取 @.sov@ 的切片，**零转换**。
--
-- ⚠️ **两类数据性质不同，不可混用一种编码**：
--
-- > 权重   : trit ∈ {0,1,2}   → 5 trit\/字节打包（'Pv'）
-- > 激活   : GF(27) 元素 ∈ [0,26]（'gf27Matmul' 的输出**不归约到 GF(3)**）
-- >          → 1 字节\/元素（'VU.Vector' 'Word8'）
--
-- 并且 @gf27Mul@ 是 **GF(27) 的多项式乘**，不是逐 trit 乘，
-- 所以**不能**把权重的 5 个 trit 与激活按"字节对"做点积（那样语义是错的）。
-- 按字节遍历只是**省内存/省分配**：一次取权重的 5 个 trit（解包）与激活的 5 个元素配对，
-- 乘法次数与原实现相同。
--
-- 位序：**最低位优先**，@powers = [1,3,9,27,81]@ —— 与
-- @scripts\/run_train._pack_trits_fast@ 一致（见 @SOV3.unpackTrits@ 的说明）。
module Infrastructure.CPU.SovereignPacked
  ( Pv(..)
  , pvFromBytes
  , pvFromTrits
  , pvToList
  , pvAt
  , bytesMasked
  , gf27PowEnc
  , gf27LogTable
  , gf27ExpTable
  , gf27MulCyclic
  , pvMatmul
  , pvMatmulList
  ) where

import qualified Data.Vector.Unboxed as VU
import Data.Word (Word8)

import Infrastructure.CPU.GF3Intrinsic (gf27ExpTable, gf27LogTable, gf27Mul, gf27MulCyclic, gf27PowEnc)
import Infrastructure.CPU.SovereignGF27 (gf27Add, gf27Zero)

-- | 3 的幂查表（最低位优先）。
pow3 :: VU.Vector Int
pow3 = VU.fromList [1, 3, 9, 27, 81]

--------------------------------------------------------------------------------
-- 权重表示：5 trit/字节
--------------------------------------------------------------------------------

-- | 打包向量：@pvN@ 个 trit 存在 @pvB@ 里，每字节 5 个（最低位优先）。
--
-- 第 @i@ 个 trit = @(pvB ! (i div 5) div 3^(i mod 5)) mod 3@。
data Pv = Pv
  { pvN :: !Int
  , pvB :: !(VU.Vector Word8)
  } deriving (Show)

-- | 从已打包字节构造（trit 数 = 字节数 × 5）。与 @.sov@ 的 @data\/N@ 直接对接。
pvFromBytes :: VU.Vector Word8 -> Pv
pvFromBytes bs = Pv (VU.length bs * 5) bs

-- | 从 trit 列表构造（trit 须在 0..2；供旧表示喂入对拍）。
pvFromTrits :: [Int] -> Pv
pvFromTrits ts = Pv n (VU.fromList (pack5 ts))
  where
    n = length ts
    pack5 xs = case splitAt 5 xs of
      ([], _)    -> []
      (c, rest)  -> fromIntegral (foldl (\a (k, t) -> a + (t `mod` 3) * (pow3 VU.! k)) 0 (zip [0 ..] c))
                    : pack5 rest

-- | 展开为 trit 列表（对照用；热路径不走这里）。
pvToList :: Pv -> [Int]
pvToList (Pv n bs) = take n (concatMap unpack5 (VU.toList bs))
  where
    unpack5 b = [ (fromIntegral b `div` (pow3 VU.! k)) `mod` 3 | k <- [0 .. 4] ]

-- | 第 @i@ 个 trit。
pvAt :: Pv -> Int -> Int
pvAt (Pv _ bs) i =
  let b = fromIntegral (bs VU.! (i `div` 5)) :: Int
  in (b `div` (pow3 VU.! (i `mod` 5))) `mod` 3

-- | 只保留字节的低 @k@ 个 trit（其余位清零）—— @mod 3^k@ 恰好做到。
truncateToTrits :: Word8 -> Int -> Word8
truncateToTrits b k
  | k >= 5    = b
  | otherwise = fromIntegral ((fromIntegral b :: Int) `mod` (3 ^ k))

-- | 取前 @n@ 个 trit 的字节视图，**末字节超出 n 的 trit 清零**，
-- 使按字节遍历时不会把权重里多余的 trit 与激活错位配对。
bytesMasked :: Int -> Pv -> VU.Vector Word8
bytesMasked n (Pv _ bs)
  | nB <= 0   = VU.empty
  | rem_ == 5 = VU.take nB bs
  | otherwise = VU.snoc (VU.take (nB - 1) bs) (truncateToTrits (bs VU.! (nB - 1)) rem_)
  where
    nB   = (n + 4) `div` 5          -- ceil(n/5)
    rem_ = n - 5 * (nB - 1)         -- 末字节有效 trit 数（1..5）

--------------------------------------------------------------------------------
-- 打包版 matmul
--------------------------------------------------------------------------------

-- | 打包权重 × 未打包激活。
--
-- @rows@ × @cols@ 的行优先打包权重，作用在长度 @cols@ 的激活向量上
-- （激活元素是 GF(27) 元素 0..26）。
-- 每行按**字节**遍历：一次解出 5 个权重 trit，与 5 个激活元素配对做 @gf27Mul@，
-- 用 'gf27Add' 累加。乘法次数与逐 trit 版相同，但权重内存降到 1\/5 × (1\/16)。
pvMatmul :: Int -> Int -> Pv -> VU.Vector Word8 -> VU.Vector Word8
pvMatmul rows cols w x = VU.generate rows (\r -> fromIntegral (rowDot r :: Int))
  where
    xb = VU.take cols x                 -- 激活仅前 cols 个有效
    nB = (cols + 4) `div` 5             -- 每行字节数（仅 cols 为 5 的倍数时行对齐）
    wb = pvB w
    -- ⚠️ 只有当 cols 是 5 的倍数时，「行 r 从字节 r*nB 开始」才成立
    -- （因为整块是扁平 5-trit 打包）。否则必须走全局 trit 索引。
    aligned = cols `mod` 5 == 0
    rowDot r
      | not aligned =
          foldl (\ !acc !j -> gf27Add acc
                   (gf27Mul (pvAt w (r * cols + j)) (fromIntegral (xb VU.! j))))
                gf27Zero [0 .. cols - 1]
      | otherwise = alignedDot r
    alignedDot !r =
      let off = r * nB
          -- 末字节可能含超出 cols 的 trit，需按位数截断；这里对激活同步截断已由 xb 保证，
          -- 只需保证不越过 cols 去取激活元素。
          go !acc !j
            | j >= nB = acc
            | otherwise =
                let byte = fromIntegral (wb VU.! (off + j)) :: Int
                    base = j * 5
                    !acc' = foldl
                      (\ !a !k ->
                         let idx = base + k
                         in if idx >= cols
                              then a
                              else gf27Add a (gf27Mul ((byte `div` (pow3 VU.! k)) `mod` 3)
                                                      (fromIntegral (xb VU.! idx))))
                      acc
                      [0 .. 4]
                in go acc' (j + 1)
      in go gf27Zero 0

-- | 未打包基线（签名与 'gf27Matmul' 一致），供逐元素对拍。
pvMatmulList :: [[Int]] -> [Int] -> [Int]
pvMatmulList w x = [ foldl gf27Add gf27Zero [ gf27Mul a b | (a, b) <- zip row x ] | row <- w ]
