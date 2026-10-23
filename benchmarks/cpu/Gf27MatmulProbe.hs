-- | 真实形状 × 三种实现 的 GF(27) matmul 公平基准（**墙钟，仅记录不作判据**）。
--
-- 回答一个问题：Haskell 'gf27Matmul' / C gather 'gf27MatmulC' / C 连续表
-- 'gf27MatmulCTable' 在同一真实形状（1440×1440、4320×1440）上谁快、快多少。
-- 之前「C matmul 220s 没加速」的测量混入了流式解包时间（222s 里 ~200s 是解包，
-- 见 SovereignFull.hs:288），本 probe 只测**纯 matmul 计算**。
module Main (main) where

import Control.Exception (evaluate)
import Data.List (foldl')
import GHC.Clock (getMonotonicTime)
import qualified Data.Vector.Storable as VS

import Infrastructure.CPU.SovereignTypes (mkGF27, mkTrit, gf27ToInt)
import Infrastructure.CPU.SovereignGF27 (gf27Matmul)
import Infrastructure.CPU.GF27SIMD (gf27MatmulC, gf27MatmulCTable, gf27MatmulCTableVec)

-- | 确定性测试数据：权重 trit {0,1,2}（真实层权重域），激活 0..26（真实激活域）。
mkW :: Int -> Int -> Int -> [[Int]]
mkW rows cols seed =
  [ [ (i * 7 + j * 5 + seed * 13) `mod` 3 | j <- [0 .. cols - 1] ]
  | i <- [0 .. rows - 1] ]
mkX :: Int -> Int -> [Int]
mkX cols seed = [ (i * 11 + seed * 3) `mod` 27 | i <- [0 .. cols - 1] ]

timeIt :: IO a -> IO (a, Double)
timeIt act = do
  t0 <- getMonotonicTime
  r <- act
  t1 <- getMonotonicTime
  _ <- evaluate (r `seq` ())
  pure (r, (t1 - t0) * 1000)

benchOne :: Int -> Int -> IO (Int, Int, Int, String)
benchOne rows cols = do
  let w = mkW rows cols 1
      x = mkX cols 2
      flatW = concat w
      hsRef = gf27Matmul (map (map mkTrit) w) (map mkGF27 x)
  _ <- evaluate (length hsRef)
  cG <- gf27MatmulC rows cols flatW x
  cT <- gf27MatmulCTable rows cols flatW x
  let hsv = map gf27ToInt hsRef
      star = if hsv == cG && cG == cT then "✓" else "✗"
  pure (rows, cols, length hsv, star)

-- | 墙钟：输入预构造（Haskell 侧 [Trit] 矩阵、C 侧扁平 Int 矩阵、激活），
-- 计时只含计算本身 —— 不把每轮 mkTrit/concat 的构造开销记进任何一边。
benchTime :: Int -> Int -> Int -> IO (Double, Double, Double, Double)
benchTime rows cols rounds = do
  let mkIn i = ( mkW rows cols ((i `mod` 27) + 1)
               , mkX cols ((i + 7) `mod` 27) )
      rawInputs = [ mkIn i | i <- [1 .. rounds] ]
      hsInputs  = [ (map (map mkTrit) ww', map mkGF27 xx) | (ww', xx) <- rawInputs ]
      cInputs   = [ (concat ww', xx) | (ww', xx) <- rawInputs ]
      -- 指针版：权重/激活预构造为 int32 常驻 Vector（FFI 只传指针）
      vInputs   = [ ( VS.fromList (map fromIntegral (concat ww'))
                    , VS.fromList (map fromIntegral xx) ) | (ww', xx) <- rawInputs ]
  _ <- evaluate (length (concat (map fst hsInputs)))
  _ <- evaluate (length (concat (map fst cInputs)))
  _ <- evaluate (VS.sum (VS.concat (map fst vInputs)))
  (_, tHs) <- timeIt
    (mapM (\(ww', xx) ->
             evaluate (foldl' (\acc r -> acc + gf27ToInt r) 0
                        (gf27Matmul ww' xx))) hsInputs)
  (_, tCg) <- timeIt
    (mapM (\(ww', xx) -> gf27MatmulC rows cols ww' xx) cInputs
     >>= \rs -> evaluate (sum (concat rs)))
  (_, tCt) <- timeIt
    (mapM (\(ww', xx) -> gf27MatmulCTable rows cols ww' xx) cInputs
     >>= \rs -> evaluate (sum (concat rs)))
  (_, tCv) <- timeIt
    (mapM (\(ww', xx) -> gf27MatmulCTableVec rows cols ww' xx) vInputs
     >>= \rs -> evaluate (VS.sum (VS.concat rs)))
  pure (tHs / fromIntegral rounds, tCg / fromIntegral rounds,
        tCt / fromIntegral rounds, tCv / fromIntegral rounds)

main :: IO ()
main = do
  putStrLn "=== GF(27) matmul 真实形状公平基准（纯计算，墙钟仅记录）==="
  let shapes = [(72, 1440, 200), (1440, 1440, 20), (4320, 1440, 6),
                (1440, 4320, 6), (1536, 1440, 20)]
  checks <- mapM (\(r, c, _) -> benchOne r c) shapes
  mapM_ (\(r, c, n, star) ->
           putStrLn ("  " ++ star ++ " 全等 [" ++ show r ++ "×" ++ show c ++
                     "] Haskell ≡ C-gather ≡ C-table（out=" ++ show n ++ "）")) checks
  results <- mapM (\(r, c, rd) -> do
                     (a, b, d, e) <- benchTime r c rd
                     pure (r, c, rd, a, b, d, e)) shapes
  mapM_ (\(r, c, rd, a, b, d, e) -> do
           putStrLn ("  [bench] " ++ show r ++ "×" ++ show c ++ " × " ++ show rd ++ " 轮 =")
           putStrLn ("    Haskell gf27Matmul      = " ++ show a ++ " ms/轮")
           putStrLn ("    C gather  matmulC      = " ++ show b ++ " ms/轮")
           putStrLn ("    C table   matmulT      = " ++ show d ++ " ms/轮")
           putStrLn ("    C table+Vec 常驻指针   = " ++ show e ++ " ms/轮")) results
  putStrLn "\n注：本机 Xeon E5-2686 v4 无 AVX512；AVX2 i32gather 是微码（慢）；OMP_NUM_THREADS 默认 36。"