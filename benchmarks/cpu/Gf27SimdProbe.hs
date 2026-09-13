-- | GF(27) 行点积 AVX2 层的对拍与基准。
--
-- 三条路必须逐元素全等：
--   1. gf27Rowdot          —— 按运行时能力（本机 Xeon E5-2686 v4 有 AVX2）
--   2. gf27RowdotScalarOnly —— C 里的标量实现（强制）
--   3. rowdotRef           —— 纯 Haskell（gf27Mul/gf27Add）
module Main (main) where

import Control.Exception (evaluate)
import Data.List (foldl')
import GHC.Clock (getMonotonicTime)

import Infrastructure.CPU.GF3Intrinsic (gf27Mul)
import Infrastructure.CPU.SovereignGF27 (gf27Add)
import Infrastructure.CPU.GF27SIMD (gf27Rowdot, gf27RowdotScalarOnly, hasAVX2)

-- | 纯 Haskell 参照（与 gf27Matmul 的 rowDot 同构）。
rowdotRef :: [Int] -> [Int] -> Int
rowdotRef ws xs = foldl' gf27Add 0 (zipWith gf27Mul ws xs)

-- | 确定性测试数据（覆盖 0..26 全域，含零元）
mkVec :: Int -> Int -> [Int]
mkVec n seed = [ (i * 7 + seed * 13) `mod` 27 | i <- [0 .. n - 1] ]

cases :: [(Int, Int)]
cases = [(1, 0), (7, 1), (8, 2), (9, 3), (16, 4), (1440, 5), (1441, 6)]

timeIt :: IO a -> IO (a, Double)
timeIt act = do
  t0 <- getMonotonicTime
  r <- act
  t1 <- getMonotonicTime
  _ <- evaluate (r `seq` ())   -- 强制求值：惰性会让计时撒谎
  pure (r, (t1 - t0) * 1000)

main :: IO ()
main = do
  avx2 <- hasAVX2
  putStrLn "=== GF(27) 行点积：AVX2 vs 标量 ==="
  putStrLn ("本机 AVX2: " ++ show avx2)

  -- 1) 正确性：三条路逐元素全等
  results <- mapM (\(n, sd) -> do
                      let w = mkVec n sd
                          x = mkVec n (sd + 100)
                      a <- gf27Rowdot w x
                      b <- gf27RowdotScalarOnly w x
                      let c = rowdotRef w x
                      pure (n, sd, a, b, c)) cases
  let bad = [ r | r@(_, _, a, b, c) <- results, not (a == b && b == c) ]
  if null bad
    then putStrLn "✓ 正确性：gf27Rowdot ≡ 标量C ≡ 纯Haskell（7 组形状，含 n=1/1440/1441 与零元）"
    else do
      putStrLn ("✗ 不一致 " ++ show (length bad) ++ " 处：")
      mapM_ print bad

  -- 2) 基准：n=1440（真实维度）× 200 轮
  let n = 1440
      rounds = 200
      -- ⚠️ 每轮换输入。否则 GHC 的 CSE 会把 200 次**相同**调用折叠成一次，
      -- 测出 "0.027ms" 这种假数字（第一版就中招了）。
      inputs = [ (mkVec n (i `mod` 27), mkVec n ((i + 7) `mod` 27)) | i <- [1 .. rounds] ]
  (_, tSimd) <- timeIt (mapM (\(w, x) -> gf27Rowdot w x) inputs >>= \rs -> evaluate (sum rs))
  (_, tScalarC) <- timeIt (mapM (\(w, x) -> gf27RowdotScalarOnly w x) inputs >>= \rs -> evaluate (sum rs))
  (_, tRef) <- timeIt (evaluate (foldl' (+) 0 (map (\(w, x) -> rowdotRef w x) inputs)))
  putStrLn ("\n基准（n=1440 × " ++ show rounds ++ " 轮，墙钟）：")
  putStrLn ("  [bench] gf27Rowdot (AVX2 派发) = " ++ show tSimd ++ " ms")
  putStrLn ("  [bench] 标量 C                = " ++ show tScalarC ++ " ms")
  putStrLn ("  [bench] 纯 Haskell            = " ++ show tRef ++ " ms")
