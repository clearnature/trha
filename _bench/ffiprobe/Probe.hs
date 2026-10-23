{-# LANGUAGE BangPatterns #-}
module Main (main) where
import Control.Exception (evaluate)
import GHC.Clock (getMonotonicTime)
import qualified Data.Vector.Storable as VS
import Infrastructure.CPU.GF27SIMD (gf27MatmulCTableVec)
import Infrastructure.CPU.SovereignFull (loadWeightsSovC)

timeIt :: IO a -> IO (a, Double)
timeIt act = do
  t0 <- getMonotonicTime; r <- act; t1 <- getMonotonicTime
  _ <- evaluate (r `seq` ())
  pure (r, (t1 - t0) * 1000)

main :: IO ()
main = do
  let rows = 1440; cols = 1440
      w0 = VS.fromList (take (rows*cols) (cycle [0,1,2 :: Int32]))
      x0 = VS.fromList [ fromIntegral i | i <- [0..cols-1] ]
  putStrLn "=== 同一进程对照：新构造 vs loadWeightsSovC 持有的向量 ==="
  -- 新构造（probe 场景）
  _ <- gf27MatmulCTableVec rows cols w0 x0
  (_, tA) <- timeIt (mapM (\_ -> gf27MatmulCTableVec rows cols w0 x0) [1..30])
                >>= \(_, t) -> pure ((), t)
  (_, tA) <- timeIt (mapM (\_ -> gf27MatmulCTableVec rows cols w0 x0) [1..30] >>= \rs -> evaluate (VS.sum (VS.concat rs)))
  putStrLn ("① 新构造 30 轮 = " ++ show (tA/30) ++ " ms/轮")
  -- 它持有的向量（真实链场景）
  ew <- loadWeightsSovC "/home/yanli/work/trha/models/20260721-033421_step31000.sov" 12
  case ew of
    Left e -> putStrLn ("loadWeightsSovC ✗ " ++ e)
    Right wc -> do
      let cl0 = head (siwCLayersC wc)
          w1 = cOutProj cl0
          x1 = VS.fromList [ fromIntegral i | i <- [0..cols-1] ]
      _ <- gf27MatmulCTableVec rows cols w1 x1
      (_, tB) <- timeIt (mapM (\_ -> gf27MatmulCTableVec rows cols w1 x1) [1..30] >>= \rs -> evaluate (VS.sum (VS.concat rs)))
      putStrLn ("② loadWeightsSovC 持有 30 轮 = " ++ show (tB/30) ++ " ms/轮")
