{-# LANGUAGE OverloadedStrings #-}

-- | GPU q/christoffel 探针：把 CPU 'christoffelInt'（z3rMatmul qW ⊗ x + transportTryte
-- + MixGF27）整条搬进 WGSL，与 CPU 逐元素对拍。这是消除「每层 CPU q + 同步点」
-- 性能瓶颈（60 层 1014ms 中 ~600ms 是它）的前置验证。
--
-- 语义（对齐 SovereignGF27.hs:107-125）：
--   qTryte[k] = Σ_j qW[k*dim + j] ⊗ (x[j] mod 3)          k ∈ [0, 72)   GF3 matmul
--   transported[h*6+k] = chiralGate[(delta+shift) mod 3]   delta=(qTryte-proto) mod 3
--   out[h*120+j] = gf27mul(encode(decode(sum transported)), x[h*120+j] mod 3)
--   （encode∘decode 对 sum ∈ [0,12] 恒等）
-- ⚠️ GF3 减法用 (a+3-b)%3 避免无符号下溢；chiralGate=[0,1,2] ⇒ r*r mod 3。
--
-- 用法：cabal run trha-webgpu-qprobe [sovPath]
--   TRHA_Q_CELL=n TRHA_Q_TARGET=m 选 (cell,target)（默认 (0,1)）
module Main (main) where

import Data.Word (Word32)
import Data.Int (Int32)
import System.Environment (getArgs, lookupEnv)
import qualified Data.Vector.Storable as VS

import Infrastructure.CPU.SovereignFull (CIntLayer (..), siwCLayersC, loadWeightsSovC)
import Infrastructure.CPU.SovereignModel (SovereignConfig (..))
import Infrastructure.CPU.SovereignIntrinsic (MixMode (..), christoffelInt)
import Infrastructure.CPU.SovereignTypes (gf27ToInt, mkTrit, Trit, tritToInt)
import Infrastructure.CPU.GF3Intrinsic (z3rDotProduct)
import Infrastructure.CPU.S2Geometry (gf3Shift, getDirection)

import Infrastructure.WebGPU.Buffer (newReadBackBuffer, newStorageBuffer, uploadWords, readWords, GpuBuffer (..))
import Infrastructure.WebGPU.Context (withContext, Context (..))
import Infrastructure.WebGPU.Kernel (newKernel, runKernel, Kernel (..))

dimD, ffD, headsD :: Int
dimD = 1440; ffD = 4320; headsD = 12

cfg0 :: SovereignConfig
cfg0 = SovereignConfig { scDim = dimD, scDepth = 60, scHeads = headsD, scVocab = 1536, scFF = ffD }

-- ═══ WGSL：域运算前缀（与 InferenceGPU 同源）═══
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
    ]

-- q kernel：两个 dispatch（qTryte[72] → out[1440]）。
-- binding: 0=x, 1=qW[72×1440], 2=proto[12×12×6], 3=shift, 4=qt(scratch 72), 5=out
qKernelWgsl :: String
qKernelWgsl =
  gf27Wgsl ++ unlines
    [ "@group(0) @binding(0) var<storage, read_write> xv: array<u32>;"
    , "@group(0) @binding(1) var<storage, read_write> qWv: array<u32>;"
    , "@group(0) @binding(2) var<storage, read_write> protos: array<u32>;"
    , "@group(0) @binding(3) var<storage, read_write> shiftv: array<u32>;"
    , "@group(0) @binding(4) var<storage, read_write> tgtv: array<u32>;"
    , "@group(0) @binding(5) var<storage, read_write> qt: array<u32>;"
    , "@group(0) @binding(6) var<storage, read_write> out: array<u32>;"
    , "@group(0) @binding(7) var<storage, read_write> sumt: array<u32>;"
    -- 阶段一：qt[k] = Σ_j qW[k*D+j] ⊗ (x[j]%3)，k ∈ [0,72)
    , "@compute @workgroup_size(64)"
    , "fn stg1(@builtin(global_invocation_id) gid: vec3<u32>) {"
    , "  let k = gid.x;"
    , "  if (k >= 72u) { return; }"
    , "  var acc = 0u;"
    , "  for (var j = 0u; j < 1440u; j++) {"
    , "    acc += gf3mul(qWv[k * 1440u + j], xv[j] % 3u);"   -- 整数累加（层2 语义，不 mod 3）
    , "  }"
    , "  qt[k] = acc;"
    , "}"
    -- 阶段二：out[h*120+j] = gf27mul(sumT_h, x[h*120+j] % 3)
    , "@compute @workgroup_size(128)"
    , "fn stg2(@builtin(global_invocation_id) gid: vec3<u32>) {"
    , "  let i = gid.x;"
    , "  if (i >= 1440u) { return; }"
    , "  let h = i / 120u;"
    , "  let j = i % 120u;"
    , "  var sumT = 0u;"
    , "  for (var kk = 0u; kk < 6u; kk++) {"
    , "    let q = qt[h * 6u + kk];"
    , "    let p = protos[h * 72u + tgtv[0] * 6u + kk];"
    , "    var d = (q + 3u - p) % 3u;"
    , "    d = (d + shiftv[0]) % 3u;"
    , "    sumT += (d * d) % 3u;"                      -- chiralGate[0,1,2] ⇒ r*r mod 3
    , "    sumt[1440u + h * 6u + kk] = d;"             -- debug: 6 deltas
    , "  }"
    , "  sumt[i] = sumT;"
    , "  out[i] = gf27mul(sumT, xv[i] % 3u);"
    , "}"
    ]

ceilW :: Int -> Word32
ceilW n = fromIntegral ((n + 255) `div` 256)

-- workgroup_size(64) 的 dispatch 组数
ceilW2 :: Int -> Int -> Word32
ceilW2 n wg = fromIntegral ((n + wg - 1) `div` wg)

main :: IO ()
main = do
  args <- getArgs
  let sov = case args of (a : _) -> a; [] -> "/home/yanli/work/trha/models/20260721-033421_step31000.sov"
  cell <- maybe 0 id . (>>= readMay) <$> lookupEnv "TRHA_Q_CELL"
  target <- maybe 1 id . (>>= readMay) <$> lookupEnv "TRHA_Q_TARGET"
  putStrLn ("=== GPU q/christoffel 探针（cell=" ++ show cell ++ ", target=" ++ show target ++ "）===")
  ewc <- loadWeightsSovC sov headsD
  case ewc of
    Left e -> putStrLn ("loadWeightsSovC ✗: " ++ e)
    Right wc -> do
      let cl0 = head (siwCLayersC wc)
          xIn = [ (i * 17 + 3) `mod` 27 | i <- [0 .. dimD - 1] ]
          -- CPU 参照：christoffelInt（权威）
          want = christoffelInt MixGF27 headsD (cQProj cl0) (cPrototype cl0) cell target
                   (map mkTrit xIn)
      putStrLn ("CPU christoffelInt 前 6: " ++ show (take 6 want))
      withContext $ \ctx -> do
        xb <- newStorageBuffer ctx (dimD * 4)
        qwb <- newStorageBuffer ctx (72 * dimD * 4)
        pb <- newStorageBuffer ctx (12 * 12 * 6 * 4)
        sb <- newStorageBuffer ctx 4
        qtb <- newStorageBuffer ctx (72 * 4)
        ob <- newStorageBuffer ctx (dimD * 4)
        sumtb <- newStorageBuffer ctx ((dimD + 12 * 6) * 4)
        rb <- newReadBackBuffer ctx (dimD * 4)
        rbt <- newReadBackBuffer ctx (72 * 4)
        rbs <- newReadBackBuffer ctx ((dimD + 12 * 6) * 4)
        uploadWords ctx xb (map fromIntegral xIn)
        uploadWords ctx qwb (map (fromIntegral . tritToInt) (concat (cQProj cl0)))
        uploadWords ctx pb (map (fromIntegral . tritToInt) (concatMap concat (cPrototype cl0)))
        -- shift = gf3Shift(cell, getDirection cell target)——从 CPU 算好传标量
        uploadWords ctx sb [fromIntegral (gf3Shift cell (getDirection cell target))]
        tb <- newStorageBuffer ctx 4
        uploadWords ctx tb [fromIntegral target]
        k1 <- newKernel ctx qKernelWgsl 8 "stg1"
        k2 <- newKernel ctx qKernelWgsl 8 "stg2"
        _ <- runKernel ctx k1 [xb, qwb, pb, sb, tb, qtb, ob, sumtb] (ceilW2 72 64, 1, 1) (Just (qtb, rbt, 72))
        got <- runKernel ctx k2 [xb, qwb, pb, sb, tb, qtb, ob, sumtb] (ceilW2 1440 128, 1, 1) (Just (ob, rb, dimD))
        sumGot <- readWords ctx rbs (dimD + 12 * 6)
        putStrLn ("head6 deltas GPU=" ++ show (map fromIntegral (take 6 (drop (1440 + 6*6) sumGot))))
        qtGot <- readWords ctx rbt 72
        let qtCpu = [ z3rDotProduct (rowOf (cQProj cl0) k) (map mkTrit xIn) | k <- [0 .. 71] ]
            bad = [ (i, g, w) | (i, (g, w)) <- zip [0 :: Int ..] (zip (map fromIntegral got) want), g /= w ]
        putStrLn ("qt[36..41] CPU=" ++ show (drop 36 qtCpu) ++ " GPU=" ++ show (drop 36 (map fromIntegral qtGot)))
        putStrLn ("sumt[769] GPU=" ++ show (sumGot !! 769))
        putStrLn ("protos[6][1][0..5]=" ++ show (map tritToInt (cPrototype cl0 !! 6 !! 1)))
        putStrLn ("protos[6][0][0..5]=" ++ show (map tritToInt (cPrototype cl0 !! 6 !! 0)))
        putStrLn ("GPU q 前 6: " ++ show (take 6 got))
        let byHead = [ (h, length [() | (i, _, _) <- bad, i `div` 120 == h]) | h <- [0 .. headsD - 1] ]
        putStrLn ("bad 按 head: " ++ show (filter ((/= 0) . snd) byHead))
        -- sumT 与 x%3 的关系：want[769]=8 = 4⊗2；sumt[769]=0 说明 GPU sumT=0
        putStrLn ("want[769]=" ++ show (want !! 769) ++ " x[769]%3=" ++ show (xIn !! 769 `mod` 3))
        if null bad
          then putStrLn "✓ GPU q/christoffel 与 CPU christoffelInt 逐元素一致 —— 可消除每层 CPU q"
          else putStrLn ("✗ 不一致 " ++ show (length bad) ++ " 处（前 6: " ++ show (take 6 bad) ++ "）")
  where
    readMay :: String -> Maybe Int
    readMay s = case reads s of [(n, "")] -> Just n; _ -> Nothing

-- | qW 的第 k 行（[dim] Trit）——CPU 参照 z3rDotProduct 用
rowOf :: [[Trit]] -> Int -> [Trit]
rowOf rows k = rows !! k
