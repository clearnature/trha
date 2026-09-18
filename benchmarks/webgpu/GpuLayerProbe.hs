{-# LANGUAGE OverloadedStrings #-}

-- | GPU 单层前向探针：把 CPU 'layerIntrinsic27C'（out/gate/up/down 4 个 matmul
-- + 残差 RMSNorm + SwiGLU 门控）整层搬进 WGSL，与 CPU 逐元素对拍。
-- 这是「60 层全 GPU 化」的最小可验证单元。
--
-- 设计（2026-09-18 profiling：单层 79.7ms 里 matmul 占 ~89%）：
--   · q/christoffel（0.014ms）留 CPU，算好上传（对拍用；生产化再考虑搬）
--   · 每层 4 个 dispatch（queue 顺序执行 = 全局屏障）：
--       A  out matmul + 残差 + rms1（同线程自含 → 可合并）
--       B  gate/up 两个 matmul（需要全 x1 → 独立 dispatch）
--       C  gated 逐分量（g ⊗ u）
--       D  down matmul + 残差 + rms2
--   · 权重 / 激活全部 u32 GF(27) 编码（0..26），与 CPU 'gf27ToInt' 一致
--
-- 对拍判据：GPU 输出（x2）与 CPU layerIntrinsic27C 逐元素一致。
--
-- ⚠️ 数据布局（与 CPU 内存定义逐字节对齐）：
--   矩阵行优先 [rows × cols]，元素 ∈ {0,1,2}（Trit）；激活 ∈ [0,26]。
module Main (main) where

import Control.Exception (evaluate)
import Data.List (foldl')
import Data.Word (Word32)
import Data.Int (Int32)
import GHC.Clock (getMonotonicTime)
import System.Environment (getArgs)

import Infrastructure.CPU.SovereignFull
  ( CIntLayer (..), siwCLayersC, loadWeightsSovC )
import Infrastructure.CPU.SovereignModel (SovereignConfig (..))
import Infrastructure.CPU.SovereignIntrinsic (MixMode (..), christoffelInt)
import Infrastructure.CPU.SovereignTypes
  ( GF27, Trit, gf27ToInt, mkGF27, mkTrit, tritToInt, mulGF27 )
import Infrastructure.CPU.SovereignGF27 (gf27Add, gf27AlphaPow, gf27Matmul, gf27RmsNorm)
import qualified Data.Vector.Storable as VS

import Infrastructure.WebGPU.Buffer (newReadBackBuffer, newStorageBuffer, uploadWords, readWords)
import Infrastructure.WebGPU.Context (withContext)
import Infrastructure.WebGPU.Kernel (newKernel, runKernel)

-- 固定规模（与真实 .sov 一致；探针只对拍层 0）
dimD, ffD, headsD :: Int
dimD = 1440; ffD = 4320; headsD = 12

cfg0 :: SovereignConfig
cfg0 = SovereignConfig { scDim = dimD, scDepth = 60, scHeads = headsD, scVocab = 1536, scFF = ffD }

-- 确定性激活（GF27 元素 0..26，与 CPU 同约定）
mkAct :: Int -> [GF27]
mkAct n = [ mkGF27 ((i * 17 + 3) `mod` 27) | i <- [0 .. n - 1] ]

-- ═══ WGSL 域运算前缀（与 CPU 乘法表逐元素等价：729 组对拍过）═══
gf27Wgsl :: String
gf27Wgsl =
  unlines
    [ "fn gf3add(a: u32, b: u32) -> u32 { return (a + b) % 3u; }"
    , "fn gf3mul(a: u32, b: u32) -> u32 { return (a * b) % 3u; }"
    , "fn gf27mul(aIn: u32, bIn: u32) -> u32 {"
    , "  let a0 = aIn % 3u; let a1 = (aIn / 3u) % 3u; let a2 = aIn / 9u;"
    , "  let b0 = bIn % 3u; let b1 = (bIn / 3u) % 3u; let b2 = bIn / 9u;"
    , "  let c0 = gf3mul(a0, b0);"
    , "  let c1 = gf3add(gf3mul(a0, b1), gf3mul(a1, b0));"
    , "  let c2 = gf3add(gf3add(gf3mul(a0, b2), gf3mul(a1, b1)), gf3mul(a2, b0));"
    , "  let c3 = gf3add(gf3mul(a1, b2), gf3mul(a2, b1));"
    , "  let c4 = gf3mul(a2, b2);"
    , "  let r2 = gf3add(c2, c4);"
    , "  let r1 = gf3add(gf3add(c1, c3), gf3mul(2u, c4));"
    , "  let r0 = gf3add(c0, gf3mul(2u, c3));"
    , "  return r0 + 3u * r1 + 9u * r2;"
    , "}"
    , "fn gf27add(aIn: u32, bIn: u32) -> u32 {"
    , "  let a0 = aIn % 3u; let a1 = (aIn / 3u) % 3u; let a2 = aIn / 9u;"
    , "  let b0 = bIn % 3u; let b1 = (bIn / 3u) % 3u; let b2 = bIn / 9u;"
    , "  return ((a0 + b0) % 3u) + 3u * ((a1 + b1) % 3u) + 9u * ((a2 + b2) % 3u);"
    , "}"
    -- 逐分量相位旋转 norm（对应 CPU gf27RmsNorm，γ=1）：x≠0 → x⊗α（α=3 的 GF27 编码）
    , "fn gfnorm(aIn: u32) -> u32 {"
    , "  if (aIn == 0u) { return 0u; }"
    , "  return gf27mul(aIn, 3u);"
    , "}"
    ]

-- matmul kernel（通用）：out[i] = Σ_j W[i,j] ⊗ x[j]，W 大小 [rows × cols]
matmulWgsl :: Int -> Int -> String
matmulWgsl rows cols =
  gf27Wgsl ++ unlines
    [ "@group(0) @binding(0) var<storage, read_write> Wv: array<u32>;"
    , "@group(0) @binding(1) var<storage, read_write> xv: array<u32>;"
    , "@group(0) @binding(2) var<storage, read_write> ov: array<u32>;"
    , "@compute @workgroup_size(256)"
    , "fn main(@builtin(global_invocation_id) gid: vec3<u32>) {"
    , "  let i = gid.x;"
    , "  if (i >= " ++ show rows ++ "u) { return; }"
    , "  var acc = 0u;"
    , "  for (var j = 0u; j < " ++ show cols ++ "u; j++) {"
    , "    acc = gf27add(acc, gf27mul(Wv[i * " ++ show cols ++ "u + j], xv[j]));"
    , "  }"
    , "  ov[i] = acc;"
    , "}"
    ]

-- 残差 + rms kernel：out[i] = norm(x[i] + res[i])
resnormWgsl :: Int -> String
resnormWgsl n =
  gf27Wgsl ++ unlines
    [ "@group(0) @binding(0) var<storage, read_write> xv: array<u32>;"
    , "@group(0) @binding(1) var<storage, read_write> rv: array<u32>;"
    , "@group(0) @binding(2) var<storage, read_write> ov: array<u32>;"
    , "@compute @workgroup_size(256)"
    , "fn main(@builtin(global_invocation_id) gid: vec3<u32>) {"
    , "  let i = gid.x;"
    , "  if (i >= " ++ show n ++ "u) { return; }"
    , "  ov[i] = gfnorm(gf27add(xv[i], rv[i]));"
    , "}"
    ]

-- gated kernel：o[i] = g[i] ⊗ u[i]
gatedWgsl :: Int -> String
gatedWgsl n =
  gf27Wgsl ++ unlines
    [ "@group(0) @binding(0) var<storage, read_write> g: array<u32>;"
    , "@group(0) @binding(1) var<storage, read_write> u: array<u32>;"
    , "@group(0) @binding(2) var<storage, read_write> o: array<u32>;"
    , "@compute @workgroup_size(256)"
    , "fn main(@builtin(global_invocation_id) gid: vec3<u32>) {"
    , "  let i = gid.x;"
    , "  if (i >= " ++ show n ++ "u) { return; }"
    , "  o[i] = gf27mul(g[i], u[i]);"
    , "}"
    ]

-- chr 配置：层 0 的 (cell,target)=(0,1) —— 与 layerIntrinsic27C 调用一致
cell, target :: Int
cell = 0; target = 1

main :: IO ()
main = do
  args <- getArgs
  let sov = case args of (a : _) -> a; [] -> "/home/yanli/work/trha/models/20260721-033421_step31000.sov"
  putStrLn "=== GPU 单层前向探针（真实权重 1440/4320/12，层 0 cell0→1）==="
  ew <- loadWeightsSovC sov headsD
  case ew of
    Left e -> putStrLn ("loadWeightsSovC ✗: " ++ e)
    Right wc -> do
      let cl0 = head (siwCLayersC wc)
          xIn = mkAct dimD
          qIn = christoffelInt MixGF27 headsD (cQProj cl0) (cPrototype cl0) cell target
                  (map (mkTrit . gf27ToInt) xIn)
      -- CPU 参照：复刻 layerIntrinsic27C 单层（导出 API 全可用）
      let c0 = cpuLayer cfg0 cl0 (cell, target) xIn qIn
      putStrLn ("CPU 单层参照前置 q: " ++ show (length qIn) ++ " 维")
      putStrLn ("CPU 输出前 6 维: " ++ show (take 6 (map gf27ToInt c0)))

      withContext $ \ctx -> do
        -- 权重（Trit 0..2）：out [D×D], gate/up [F×D], down [D×F]
        let wOutFlat = flattenTrit (cOutProj cl0)
            wGateFlat = flattenTrit (cGateProj cl0)
            wUpFlat = flattenTrit (cUpProj cl0)
            wDownFlat = flattenTrit (cDownProj cl0)
        wb <- newStorageBuffer ctx (dimD * dimD * 4)
        gb <- newStorageBuffer ctx (ffD * dimD * 4)
        ub <- newStorageBuffer ctx (ffD * dimD * 4)
        db <- newStorageBuffer ctx (dimD * ffD * 4)
        uploadWords ctx wb (map fromIntegral wOutFlat)
        uploadWords ctx gb (map fromIntegral wGateFlat)
        uploadWords ctx ub (map fromIntegral wUpFlat)
        uploadWords ctx db (map fromIntegral wDownFlat)

        -- 激活 buffer
        xb <- newStorageBuffer ctx (dimD * 4)
        qb <- newStorageBuffer ctx (dimD * 4)
        a1 <- newStorageBuffer ctx (dimD * 4)        -- x1 = norm(x + out)
        gf <- newStorageBuffer ctx (ffD * 4)          -- gate
        uf <- newStorageBuffer ctx (ffD * 4)          -- up
        ged <- newStorageBuffer ctx (ffD * 4)         -- gated
        a2 <- newStorageBuffer ctx (dimD * 4)         -- x2 = norm(x1 + down)
        rb <- newReadBackBuffer ctx (dimD * 4)
        uploadWords ctx xb (map (fromIntegral . gf27ToInt) xIn)
        uploadWords ctx qb (map fromIntegral qIn)

        -- 4 个 kernel
        kOut  <- newKernel ctx (matmulWgsl dimD dimD) 3 "main"
        kGUp  <- newKernel ctx (matmulWgsl ffD dimD) 3 "main"
        kGated<- newKernel ctx (gatedWgsl ffD) 3 "main"
        kDown <- newKernel ctx (matmulWgsl dimD ffD) 3 "main"
        kRN1  <- newKernel ctx (resnormWgsl dimD) 3 "main"
        kRN2  <- newKernel ctx (resnormWgsl dimD) 3 "main"

        -- A: out = W ⊗ q（写 a1 临时）；rms1 = norm(x + out)
        _ <- runKernel ctx kOut [wb, qb, a1] (ceilW dimD, 1, 1) Nothing
        _ <- runKernel ctx kRN1 [xb, a1, a1] (ceilW dimD, 1, 1) Nothing
        -- B: gate/up（kOut 内核复用：矩阵不变量 rows×cols 由 kernel 内常量定）
        _ <- runKernel ctx kGUp [gb, a1, gf] (ceilW ffD, 1, 1) Nothing
        _ <- runKernel ctx kGUp [ub, a1, uf] (ceilW ffD, 1, 1) Nothing
        -- C: gated
        _ <- runKernel ctx kGated [gf, uf, ged] (ceilW ffD, 1, 1) Nothing
        -- D: down + rms2
        _ <- runKernel ctx kDown [db, ged, a2] (ceilW dimD, 1, 1) Nothing
        t0 <- getMonotonicTime
        got <- runKernel ctx kRN2 [a1, a2, a2] (ceilW dimD, 1, 1) (Just (a2, rb, dimD))
        t1 <- getMonotonicTime

        let want = map gf27ToInt c0
            bad = [ (i, got !! i, want !! i) | i <- [0 .. dimD - 1], got !! i /= fromIntegral (want !! i) ]
        putStrLn ("GPU 墙钟（5 dispatch，含读回）: " ++ show ((t1 - t0) * 1000) ++ " ms")
        putStrLn ("GPU 前 6: " ++ show (take 6 got))
        if null bad
          then putStrLn "✓ GPU 单层与 CPU layerIntrinsic27C 逐元素一致 —— 60 层全 GPU 化可行"
          else putStrLn ("✗ 不一致 " ++ show (length bad) ++ " 处（前 6 例）: " ++ show (take 6 bad))

-- | [[Trit]] → 扁平行优先 int32（Trit 编码 0..2；这里直接 CIntLayer 存的是 Int32 域）
flattenTrit :: VS.Vector Int32 -> [Int]
flattenTrit = map fromIntegral . VS.toList

ceilW :: Int -> Word32
ceilW n = fromIntegral ((n + 255) `div` 256)

-- 计时（墙钟，仅记录）
timeIt :: IO a -> IO (a, Double)
timeIt act = do
  t0 <- getMonotonicTime
  r <- act
  t1 <- getMonotonicTime
  _ <- evaluate r
  pure (r, (t1 - t0) * 1000)
-- | CPU 单层参照（复刻 layerIntrinsic27C，用导出的 gf27Matmul / gf27RmsNorm /
-- 与 SovereignTypes 的权威 'mulGF27'）：
-- x1 = rms(x + out⊗q) → g/u = Wg/Wu⊗x1 → gated = g⊗u → d = Wd⊗gated → x2 = rms(x1+d)
cpuLayer :: SovereignConfig -> CIntLayer -> (Int, Int) -> [GF27] -> [Int] -> [GF27]
cpuLayer cfg cl _cellTarget x qIn =
  let _heads = scHeads cfg; dim = scDim cfg; ff = scFF cfg
      gamma = replicate dim (mkGF27 1)
      qGF27 = map (mkGF27 . fromIntegral) qIn      -- christoffel 结果（GF27）
      o  = gf27Matmul (wRows (cOutProj cl) dim dim) qGF27   -- out matmul 吃 q！
      x1 = gf27RmsNorm gamma (zipWith addGF27 x o)
      g  = gf27Matmul (wRows (cGateProj cl) ff dim) x1
      u  = gf27Matmul (wRows (cUpProj cl)   ff dim) x1
      gated = zipWith mulGF27 g u
      d  = gf27Matmul (wRows (cDownProj cl) dim ff) gated
      x2 = gf27RmsNorm gamma (zipWith addGF27 x1 d)
  in x2
  where
    addGF27 a b = mkGF27 (gf27Add (gf27ToInt a) (gf27ToInt b))
    -- 行优先 [rows×cols] VS.Vector Int32 → [[Trit]]
    wRows v rows cols = [ [ mkTrit (fromIntegral (v VS.! (r * cols + c)))
                          | c <- [0 .. cols - 1] ]
                        | r <- [0 .. rows - 1] ]
