-- | GF(27) 矩阵乘 GPU kernel —— 从"单个运算"走向"一层网络"，并给出首个 GPU/CPU 实测对比。
--
-- 算例：y[i] = Σ_j (w[i][j] ⊗ x[j])，其中 w 是 Trit（0..2，GF(3) 元素）、
-- x/y 是 GF(27) 元素 —— 与 CPU 侧 Infrastructure.CPU.SovereignGF27.gf27Matmul 同约定：
--   gf27Matmul :: [[Trit]] -> [GF27] -> [GF27]
--
-- 计时（T2）：用 GHC.Clock.getMonotonicTime（base 自带，单调时钟、零新依赖）。
-- **诚实标注**：这是墙钟时间，含提交往返与主机侧开销，不是纯 GPU 内核时间；
-- 纯内核时间需要 GPU 时间戳查询（需 feature，另一条路）。用来区分"真算"与旧层那种
-- threadDelay 假计时，这个精度足够。
module Main (main) where

import Control.Exception (evaluate)
import System.Environment (lookupEnv)
import Data.List (foldl')
import Data.Word (Word32)
import GHC.Clock (getMonotonicTime)

import Infrastructure.CPU.SovereignGF27 (gf27Matmul)
import Infrastructure.CPU.SovereignTypes (gf27ToInt, mkGF27, mkTrit)
import Infrastructure.WebGPU.Buffer (newReadBackBuffer, newStorageBuffer, uploadWords)
import Infrastructure.WebGPU.Context (withContext)
import Infrastructure.WebGPU.Kernel (newKernel, runKernel)

-- 规模可用环境变量覆盖（便于看"规模效应"）：TRHA_GF27_M / TRHA_GF27_K，默认 64×64
readDim :: String -> Int -> IO Int
readDim name def = maybe def (\v -> maybe def id (readMaybeInt v)) <$> lookupEnv name
  where
    readMaybeInt v = case reads v :: [(Int, String)] of
      [(n, "")] -> Just n
      _ -> Nothing

-- 确定性权重（trit 0..2）与输入（GF27 0..26）
weightsOf :: Int -> Int -> [[Int]]
weightsOf m k = [[(i * 7 + j * 13) `mod` 3 | j <- [0 .. k - 1]] | i <- [0 .. m - 1]]

inputOf :: Int -> [Int]
inputOf k = [(j * 11) `mod` 27 | j <- [0 .. k - 1]]

-- | GF(27) 加法（逐分量 mod 3）+ 乘法（多项式乘 + 归约，α³ = α+2）—— 与 CPU 同约定。
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
    ]

wgsl :: String
wgsl =
  gf27Wgsl
    ++ unlines
      [ "@group(0) @binding(0) var<storage, read_write> wv: array<u32>;"
      , "@group(0) @binding(1) var<storage, read_write> xv: array<u32>;"
      , "@group(0) @binding(2) var<storage, read_write> yv: array<u32>;"
      , "@group(0) @binding(3) var<storage, read_write> dims: array<u32>;"
      , "@compute @workgroup_size(64)"
      , "fn main(@builtin(global_invocation_id) gid: vec3<u32>) {"
      , "  let i = gid.x;"
      , "  let m = dims[0]; let k = dims[1];"
      , "  if (i >= m) { return; }"
      , "  var acc = 0u;"
      , "  for (var j = 0u; j < k; j++) {"
      , "    acc = gf27add(acc, gf27mul(wv[i * k + j], xv[j]));"
      , "  }"
      , "  yv[i] = acc;"
      , "}"
      ]

main :: IO ()
main = withContext $ \ctx -> do
  mDim <- readDim "TRHA_GF27_M" 64
  kDim <- readDim "TRHA_GF27_K" 64
  putStrLn "=== GF(27) 矩阵乘 GPU↔CPU（含实测计时）==="
  putStrLn ("规模: " ++ show mDim ++ "×" ++ show kDim ++ " 权重 ⊗ " ++ show kDim ++ " 向量")
  let weights = weightsOf mDim kDim
      inputVec = inputOf kDim

  let wBytes = mDim * kDim * 4
      xBytes = kDim * 4
      yBytes = mDim * 4

  wb <- newStorageBuffer ctx wBytes
  xb <- newStorageBuffer ctx xBytes
  yb <- newStorageBuffer ctx yBytes
  rb <- newReadBackBuffer ctx yBytes

  uploadWords ctx wb (concatMap (map fromIntegral) weights)
  uploadWords ctx xb (map fromIntegral inputVec)
  dimsBuf <- newStorageBuffer ctx 8
  uploadWords ctx dimsBuf [fromIntegral mDim, fromIntegral kDim]

  k <- newKernel ctx wgsl 4 "main"

  -- T2：GPU 墙钟（单调时钟）
  t0 <- getMonotonicTime
  got <- runKernel ctx k [wb, xb, yb, dimsBuf] (fromIntegral (mDim `div` 64), 1, 1) (Just (yb, rb, mDim))
  t1 <- getMonotonicTime

  -- CPU 参照（含它自己的计时，同为墙钟）
  let wTrit = map (map mkTrit) weights
      xGF27 = map mkGF27 inputVec
  c0 <- getMonotonicTime
  -- ⚠️ 必须强制求值：Haskell 惰性，直接 let 只会构造 thunk，计时会得到荒谬的
  -- 纳秒级数字（实测 4.2e-5 ms，比真正计算快 5 个数量级）。
  let want = map gf27ToInt (gf27Matmul wTrit xGF27)
  _ <- evaluate (foldl' (+) 0 want)
  c1 <- getMonotonicTime

  let gpuMs = (t1 - t0) * 1000
      cpuMs = (c1 - c0) * 1000
      bad = [ (i, got !! i, want !! i) | i <- [0 .. mDim - 1], got !! i /= fromIntegral (want !! i) ]

  putStrLn ("GPU（墙钟，含提交往返）: " ++ show gpuMs ++ " ms")
  putStrLn ("CPU（gf27Matmul，墙钟）  : " ++ show cpuMs ++ " ms")
  putStrLn ("  ⚠️ 均为墙钟、含各自开销；不是纯内核时间。CPU 侧是单线程 list 实现。")
  if null bad
    then putStrLn "✓ GPU 结果与 CPU gf27Matmul 逐元素一致 —— GF(27) matmul kernel 通过"
    else do
      putStrLn ("✗ 不一致 " ++ show (length bad) ++ " 处，前 3 例（下标, GPU, CPU）：")
      mapM_ print (take 3 bad)
