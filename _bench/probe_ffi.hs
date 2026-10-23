-- 对照：纯 C 1.63ms（含拷权重） vs Haskell FFI gf27MatmulCTableVec 每轮
-- 到底多少？（profile 的 S2 报 7.5ms，把序列化/分配/求值混进去了。）
module Main (main) where
import Control.Exception (evaluate)
import GHC.Clock (getMonotonicTime)
import qualified Data.Vector.Storable as VS
import Infrastructure.CPU.GF27SIMD (gf27MatmulCTableVec)

timeIt :: IO a -> IO (a, Double)
timeIt act = do
  t0 <- getMonotonicTime; r <- act; t1 <- getMonotonicTime
  _ <- evaluate (r `seq` ())
  pure (r, (t1 - t0) * 1000)

main :: IO ()
main = do
  let rows = 1440; cols = 1440
      w = VS.fromList (take (rows*cols) (cycle [0,1,2 :: Int32]))
      x = VS.fromList [ fromIntegral i | i <- [0..cols-1] ]
  -- 预热
  _ <- gf27MatmulCTableVec rows cols w x
  -- 裸调用（不转列表）
  (_, t0) <- timeIt (mapM (\_ -> gf27MatmulCTableVec rows cols w x) [1..30] >>= \rs -> evaluate (VS.length (VS.concat rs)))
  putStrLn ("裸 FFI 30 轮 = " ++ show (t0/30) ++ " ms/轮")
  -- 转列表（profile 的求值方式）
  (_, t1) <- timeIt (mapM (\_ -> gf27MatmulCTableVec rows cols w x) [1..30] >>= \rs -> evaluate (length (concatMap VS.toList rs)))
  putStrLn ("转列表 30 轮 = " ++ show (t1/30) ++ " ms/轮")
  putStrLn ("真实稳态参考：trha-cpu-real60 = 1826ms/token（60 层）")
