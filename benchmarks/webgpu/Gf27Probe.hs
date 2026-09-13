-- | GF(27) 乘法 kernel：把项目的三值代数搬到 GPU，与 CPU 实现全 729 组对拍。
--
-- GF(27) = GF(3³)，不可约多项式约定 α³ = α + 2（见
-- src/Infrastructure/CPU/SovereignGF27.hs:14）。元素编码为三位三进制：
--   n = n0 + 3·n1 + 9·n2   （n0,n1,n2 ∈ GF(3)）
-- 乘法 = 常规多项式乘（次数 0..4）+ 归约（α³ → α+2，α⁴ → α²+2α）。
--
-- 这里**不用查表**（CPU 侧的 gf27Mul 是 729 项查表版），而是逐位算 —— 与 gf27MulRef
-- 是同一算法，因此二者互为独立参照，对拍才有效。
module Main (main) where

import Data.Word (Word32)

import Infrastructure.CPU.GF3Intrinsic (gf27MulRef)
import Infrastructure.WebGPU.Buffer (newReadBackBuffer, newStorageBuffer, uploadWords)
import Infrastructure.WebGPU.Context (withContext)
import Infrastructure.WebGPU.Kernel (newKernel, runKernel)

-- | 全部 27×27 = 729 组有序对。
pairs :: [(Int, Int)]
pairs = [(a, b) | a <- [0 .. 26], b <- [0 .. 26]]

n :: Int
n = length pairs

wgsl :: String
wgsl =
  unlines
    [ "// GF(27)=GF(3^3), alpha^3 = alpha + 2"
    , "fn gf3add(a: u32, b: u32) -> u32 { return (a + b) % 3u; }"
    , "fn gf3mul(a: u32, b: u32) -> u32 { return (a * b) % 3u; }"
    , "fn gf27mul(aIn: u32, bIn: u32) -> u32 {"
    , "  let a0 = aIn % 3u; let a1 = (aIn / 3u) % 3u; let a2 = aIn / 9u;"
    , "  let b0 = bIn % 3u; let b1 = (bIn / 3u) % 3u; let b2 = bIn / 9u;"
    , "  // 多项式乘：次数 0..4"
    , "  let c0 = gf3mul(a0, b0);"
    , "  let c1 = gf3add(gf3mul(a0, b1), gf3mul(a1, b0));"
    , "  let c2 = gf3add(gf3add(gf3mul(a0, b2), gf3mul(a1, b1)), gf3mul(a2, b0));"
    , "  let c3 = gf3add(gf3mul(a1, b2), gf3mul(a2, b1));"
    , "  let c4 = gf3mul(a2, b2);"
    , "  // 归约：alpha^4 = alpha^2 + 2*alpha ; alpha^3 = alpha + 2"
    , "  let r2 = gf3add(c2, c4);"
    , "  let r1 = gf3add(gf3add(c1, c3), gf3mul(2u, c4));"
    , "  let r0 = gf3add(c0, gf3mul(2u, c3));"
    , "  return r0 + 3u * r1 + 9u * r2;"
    , "}"
    , "@group(0) @binding(0) var<storage, read_write> av: array<u32>;"
    , "@group(0) @binding(1) var<storage, read_write> bv: array<u32>;"
    , "@group(0) @binding(2) var<storage, read_write> cv: array<u32>;"
    , "@compute @workgroup_size(256)"
    , "fn main(@builtin(global_invocation_id) gid: vec3<u32>) {"
    , "  let i = gid.x;"
    , "  if (i >= 729u) { return; }"
    , "  cv[i] = gf27mul(av[i], bv[i]);"
    , "}"
    ]

main :: IO ()
main = withContext $ \ctx -> do
  putStrLn "=== GF(27) 乘法 GPU↔CPU 对拍（全部 27×27 = 729 组）==="
  let bytes = n * 4
  av <- newStorageBuffer ctx bytes
  bv <- newStorageBuffer ctx bytes
  cv <- newStorageBuffer ctx bytes
  rb <- newReadBackBuffer ctx bytes

  uploadWords ctx av (map (fromIntegral . fst) pairs)
  uploadWords ctx bv (map (fromIntegral . snd) pairs)

  -- 729 个元素 / workgroup_size 256 → 3 个工作组
  k <- newKernel ctx wgsl 3 "main"
  got <- runKernel ctx k [av, bv, cv] (3, 1, 1) (Just (cv, rb, n))

  let want = map (fromIntegral . uncurry gf27MulRef) pairs :: [Word32]
      bad = [ (i, got !! i, want !! i) | i <- [0 .. n - 1], got !! i /= want !! i ]
  putStrLn ("样本数: " ++ show n)
  if null bad
    then putStrLn "✓ GPU 结果与 CPU gf27MulRef 全 729 组逐元素一致 —— GF(27) kernel 通过"
    else do
      putStrLn ("✗ 不一致 " ++ show (length bad) ++ " 处，前 5 例（下标, GPU, CPU）：")
      mapM_ print (take 5 bad)
