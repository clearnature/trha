-- | 真实权重・层内分段 profiling（墙钟，仅记录）。
--
-- 回答用户问题②「层内 q/christoffel + RmsNorm 占多少？」——把 'layerIntrinsic27C'
-- 的 5 个计算段拆开计时（真实 .sov 第 0 层权重，S1/S3 单次、S2/S4/S5 多轮均值），
-- 给出各自占比，判断「进 C 后能到多少」。
module Main (main) where

import Control.Exception (evaluate)
import Data.Int (Int32)
import GHC.Clock (getMonotonicTime)
import System.Environment (getArgs)

import Infrastructure.CPU.SovereignFull
  ( loadWeightsSovC, CIntLayer(..), SovereignIntWeightsC(..) )
import Infrastructure.CPU.SovereignModel (SovereignConfig(..))
import Infrastructure.CPU.SovereignIntrinsic (christoffelInt, MixMode(..))
import Infrastructure.CPU.SovereignGF27 (gf27Add, gf27RmsNorm)
import Infrastructure.CPU.GF3Intrinsic (gf27Mul)
import Infrastructure.CPU.GF27SIMD (gf27MatmulCTableVec)
import qualified Infrastructure.CPU.SovereignTypes as ST
import qualified Data.Vector.Storable as VS

timeIt :: IO a -> IO (a, Double)
timeIt act = do
  t0 <- getMonotonicTime
  r <- act
  t1 <- getMonotonicTime
  _ <- evaluate (r `seq` ())
  pure (r, (t1 - t0) * 1000)

cfg :: SovereignConfig
cfg = SovereignConfig { scDim = 1440, scDepth = 60, scHeads = 12
                      , scVocab = 1536, scFF = 4320, scEps = 1e-5 }

mkAct :: Int -> [ST.GF27]
mkAct n = [ ST.mkGF27 (i `mod` 27) | i <- [0 .. n - 1] ]

main :: IO ()
main = do
  args <- getArgs
  let sov = case args of (a : _) -> a; [] -> "/home/yanli/work/trha/models/20260721-033421_step31000.sov"
      rounds = 30
      dim = 1440; ff = 4320; heads = 12
      (cell, target) = (0, 1)
      gamma = replicate dim ST.gf27One
      x = mkAct dim
      addGF27 a b = ST.mkGF27 (gf27Add (ST.gf27ToInt a) (ST.gf27ToInt b))
      mulGF27 a b = ST.mkGF27 (gf27Mul (ST.gf27ToInt a) (ST.gf27ToInt b))
  putStrLn "=== 真实权重・层 0 分段 profiling（墙钟，仅记录）==="
  (ew, _) <- timeIt (loadWeightsSovC sov 12)
  case ew of
    Left e -> putStrLn ("  loadWeightsSovC ✗: " ++ e)
    Right wc -> do
      let cl0 = head (siwCLayersC wc)
      -- 预热
      _ <- evaluate (christoffelInt MixGF27 heads (cQProj cl0) (cPrototype cl0) cell target
                       (map (ST.mkTrit . ST.gf27ToInt) x))
      -- S1 q/christoffel（Haskell，纯）
      (_, tQ) <- timeIt (evaluate (christoffelInt MixGF27 heads (cQProj cl0) (cPrototype cl0) cell target
                                     (map (ST.mkTrit . ST.gf27ToInt) x)))
      putStrLn ("  S1 q/christoffel（Haskell 纯）     = " ++ show tQ ++ " ms")
      -- S2 out matmul（C 双表）
      let xTru = VS.fromList (map fromIntegral (take dim (cycle [3,7,21,5,15,23,13,17,20,4,12,14,11,2,6,18])))
          qOut = christoffelInt MixGF27 heads (cQProj cl0) (cPrototype cl0) cell target
                   (map (ST.mkTrit . ST.gf27ToInt) x)
          qVec = VS.fromList (map fromIntegral qOut)
      (_, tO) <- timeIt
        (mapM (\_ -> gf27MatmulCTableVec dim dim (cOutProj cl0) qVec) [1 .. rounds]
         >>= \rs -> evaluate (VS.length (VS.concat rs)))
      putStrLn ("  S2 out matmul（真实 qVec 输入）    = " ++ show (tO / fromIntegral rounds) ++ " ms/轮")
      -- 若 qVec 构造在耗时：先强制再测
      _ <- evaluate (VS.length qVec)
      (_, tO3) <- timeIt
        (mapM (\_ -> gf27MatmulCTableVec dim dim (cOutProj cl0) (VS.force qVec)) [1 .. rounds]
         >>= \rs -> evaluate (VS.length (VS.concat rs)))
      putStrLn ("  S2'' 预强制 qVec                   = " ++ show (tO3 / fromIntegral rounds) ++ " ms/轮")
      -- 同权重、换输入：常量幂次（对照）看 matmul 本身
      (_, tO2) <- timeIt
        (mapM (\_ -> gf27MatmulCTableVec dim dim (cOutProj cl0) xTru) [1 .. rounds]
         >>= \rs -> evaluate (VS.length (VS.concat rs)))
      putStrLn ("  S2' out matmul（常量幂次输入）     = " ++ show (tO2 / fromIntegral rounds) ++ " ms/轮")
      -- S3 rmsnorm + 残差（Haskell）
      o0 <- gf27MatmulCTableVec dim dim (cOutProj cl0) qVec
      let oL = map (ST.mkGF27 . fromIntegral) (VS.toList o0)
          x1 = gf27RmsNorm gamma (zipWith addGF27 x oL)
      (_, tR1) <- timeIt (evaluate (length (gf27RmsNorm gamma (zipWith addGF27 x oL))))
      putStrLn ("  S3 rmsnorm+残差（Haskell）        = " ++ show tR1 ++ " ms")
      -- S4 gate/up（C ×2）+ gated（Haskell）
      let x1v = VS.fromList (map (fromIntegral . ST.gf27ToInt) x1)
      _ <- evaluate (VS.length x1v)
      (_, tGU) <- timeIt
        (mapM (\_ -> do
                 gI <- gf27MatmulCTableVec ff dim (cGateProj cl0) x1v
                 uI <- gf27MatmulCTableVec ff dim (cUpProj cl0) x1v
                 let g = map (ST.mkGF27 . fromIntegral) (VS.toList gI)
                     u = map (ST.mkGF27 . fromIntegral) (VS.toList uI)
                 evaluate (length (zipWith mulGF27 g u)))
              [1 .. rounds])
      putStrLn ("  S4 gate/up matmul×2 + gated       = " ++ show (tGU / fromIntegral rounds) ++ " ms/轮")
      -- S5 down matmul（C）+ rmsnorm2
      (gI, uI) <- (,) <$> gf27MatmulCTableVec ff dim (cGateProj cl0) x1v
                      <*> gf27MatmulCTableVec ff dim (cUpProj cl0) x1v
      let g = map (ST.mkGF27 . fromIntegral) (VS.toList gI)
          u = map (ST.mkGF27 . fromIntegral) (VS.toList uI)
          gated = zipWith mulGF27 g u
          gatedV = VS.fromList (map (fromIntegral . ST.gf27ToInt) gated)
      _ <- evaluate (VS.length gatedV)
      (_, tD) <- timeIt
        (mapM (\_ -> gf27MatmulCTableVec dim ff (cDownProj cl0) gatedV) [1 .. rounds]
         >>= \rs -> evaluate (length (concatMap VS.toList rs)))
      putStrLn ("  S5 down matmul（C 双表）          = " ++ show (tD / fromIntegral rounds) ++ " ms/轮")
      let perLayer = (tQ + tR1) + (tO + tGU + tD) / fromIntegral rounds
      putStrLn ("  单层合计 ≈ " ++ show perLayer ++ " ms → 60 层 ≈ " ++ show (perLayer * 60 / 1000) ++ " s")
      putStrLn ("  （S2/S4/S5 为 " ++ show rounds ++ " 轮均值；S1/S3 单次墙钟参考）")
      -- ☆ 嫌疑定位：S2 的输入 qVec 来自 christoffelInt 输出 → 打印其长度/值域
      let qOutLen = length qOut
          qOutMax = if null qOut then 0 else maximum qOut
          qOutMin = if null qOut then 0 else minimum qOut
      putStrLn ("  [诊断] q(christoffel) 输出：len=" ++ show qOutLen ++ " min=" ++ show qOutMin ++ " max=" ++ show qOutMax ++ "（dim=" ++ show dim ++ "）")
      -- 对照：同形状下「新构造向量」vs「loadWeightsSovC 持有向量」，分辨 pinning 嫌疑
      let wNew = VS.fromList (take (dim*dim) (cycle [0,1,2 :: Int32]))
          xNew = VS.fromList (map fromIntegral (take dim (cycle [3,7,21,5,15,23,13,17,20,4,12,14,11,2,6,18])))
          xTru = VS.fromList (map fromIntegral (take dim (cycle [3,7,21,5,15,23,13,17,20,4,12,14,11,2,6,18])))
      _ <- gf27MatmulCTableVec dim dim wNew xNew
      (_, tN) <- timeIt (mapM (\_ -> gf27MatmulCTableVec dim dim wNew xNew) [1..rounds]
                       >>= \rs -> evaluate (VS.length (VS.concat rs)))
      let wHeld = cOutProj cl0
      _ <- gf27MatmulCTableVec dim dim wHeld xTru
      (_, tH) <- timeIt (mapM (\_ -> gf27MatmulCTableVec dim dim wHeld xTru) [1..rounds]
                       >>= \rs -> evaluate (VS.length (VS.concat rs)))
      putStrLn ("  [对照] 新构造向量 = " ++ show (tN/fromIntegral rounds) ++ " ms/轮 · 持有向量 = " ++ show (tH/fromIntegral rounds) ++ " ms/轮")
      putStrLn ("  对照结论判据：新构造≪持有 ⇒ pinning/GC 嫌疑；两者都≈7.5 ⇒ FFI 本身开销量级")