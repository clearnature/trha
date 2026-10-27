-- | WebGPU 真机测试（独立 test-suite）。
--
-- 为什么不塞进 test/Spec.hs：
--   1) 主套件 2000+ 行、且**不需要 GPU**就该能跑；GPU 测试放进去会让它在无 GPU 环境
--      整体失败（而不是跳过）；
--   2) 隔离依赖：这里需要 trha-webgpu + trha-llm（取 CPU 侧参照），主套件不需要。
--
-- 无可用 GPU / 无 wgpu-native 时，用 pending 兜底而不是失败 —— 这样 CI（无 GPU）也能绿。
module Main (main) where

import Control.Exception (evaluate)
import Control.Monad (when)
import Data.List (foldl')
import Data.Word (Word32)
import Test.Hspec

import Infrastructure.CPU.GF3Intrinsic (gf27Mul, gf27MulRef)
import Infrastructure.CPU.GF27SIMD (gf27Rowdot, gf27RowdotScalarOnly, hasAVX2)
import Infrastructure.CPU.SovereignGF27 (gf27Add)
import Infrastructure.CPU.SovereignGF27 (gf27Matmul)
import Infrastructure.CPU.SovereignTypes (gf27ToInt, mkGF27, mkTrit)
import Infrastructure.WebGPU.Buffer (newReadBackBuffer, newStorageBuffer, uploadWords)
import Infrastructure.WebGPU.Context (Context (..), createContext)
import Infrastructure.WebGPU.Kernel (newKernel, runKernel)

-- | GF(27) 乘法内核的 WGSL（与 benchmarks/webgpu/Gf27Probe.hs 同一算法）
gf27MulWgsl :: String
gf27MulWgsl =
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

-- | 在给定上下文上跑一次 GF(27) 乘法内核，返回 729 个结果。
runGf27Mul :: Context -> IO [Word32]
runGf27Mul ctx = do
  let pairs = [(a, b) | a <- [0 .. 26], b <- [0 .. 26]] :: [(Int, Int)]
      n = length pairs
      bytes = n * 4
  av <- newStorageBuffer ctx bytes
  bv <- newStorageBuffer ctx bytes
  cv <- newStorageBuffer ctx bytes
  rb <- newReadBackBuffer ctx bytes
  uploadWords ctx av (map (fromIntegral . fst) pairs)
  uploadWords ctx bv (map (fromIntegral . snd) pairs)
  k <- newKernel ctx gf27MulWgsl 3 "main"
  runKernel ctx k [av, bv, cv] (3, 1, 1) (Just (cv, rb, n))

main :: IO ()
main = do
  ctxE <- createContext
  case ctxE of
    Left msg ->
      hspec $
        describe "WebGPU（真机）" $
          it "需要可用的 GPU" $
            pendingWith ("无可用 WebGPU 适配器/设备：" ++ msg)
    Right ctx ->
      hspec $ do
        describe "WebGPU（真机）" $ do
          it "GF(27) 乘法内核 ≡ CPU gf27MulRef（全 729 组）" $ do
            got <- runGf27Mul ctx
            let want = map (fromIntegral . uncurry gf27MulRef)
                           [ (a, b) | a <- [0 .. 26], b <- [0 .. 26] ]
            got `shouldBe` want

          it "GF(27) matmul 内核 ≡ CPU gf27Matmul（16×32）" $ do
            let m = 16
                kk = 32
                weights = [[(i * 7 + j * 13) `mod` 3 | j <- [0 .. kk - 1]] | i <- [0 .. m - 1]]
                xs = [(j * 11) `mod` 27 | j <- [0 .. kk - 1]]
                wBytes = m * kk * 4
                xBytes = kk * 4
                yBytes = m * 4
            wb <- newStorageBuffer ctx wBytes
            xb <- newStorageBuffer ctx xBytes
            yb <- newStorageBuffer ctx yBytes
            rb <- newReadBackBuffer ctx yBytes
            dimsBuf <- newStorageBuffer ctx 8
            uploadWords ctx wb (concatMap (map fromIntegral) weights)
            uploadWords ctx xb (map fromIntegral xs)
            uploadWords ctx dimsBuf [fromIntegral m, fromIntegral kk]
            kern <- newKernel ctx matmulWgsl 4 "main"
            got <- runKernel ctx kern [wb, xb, yb, dimsBuf] (1, 1, 1) (Just (yb, rb, m))
            let want = map (fromIntegral . gf27ToInt)
                           (gf27Matmul (map (map mkTrit) weights) (map mkGF27 xs))
            -- 强制求值，避免惰性 thunk 让 shouldBe 比较到未求值结构（无实际影响，
            -- 但保持与基准脚本一致的严格性）
            _ <- evaluate (foldl' (+) 0 want)
            got `shouldBe` want

          it "★ C3 四实现全等：Haskell 标量 / C 标量 / AVX2 / GPU 在同一批输入上一致" $ do
            -- 判据 C3 的完整形式：同一数学结构（GF(27) 行点积）的**四个独立实现**
            -- 在**同一批输入**上结果全等。此前四者的对拍分散在两个套件里
            -- （① ② ③ 在 trha-cpu-test，④ 在 test-webgpu），从未同批对照过。
            --
            -- 取 4 组覆盖边界与不同长度（含 1 / 8 / 9 / 33，后者跨 AVX2 的 8 路块）。
            let cases =
                  [ ([], [])
                  , ([1], [1])
                  , ( [0, 1, 2, 3, 4, 5, 6, 7]
                    , [8, 7, 6, 5, 4, 3, 2, 1] )
                  , ( map (\i -> (i * 7 + 3) `mod` 27) [0 .. 32]
                    , map (\i -> (i * 11 + 5) `mod` 27) [0 .. 32] )
                  ]
            avx <- hasAVX2
            mapM_ (checkCase avx ctx) cases



-- | 对一组输入跑四实现对照：① Haskell 标量 ② C 标量 ③ AVX2 ④ GPU（行点积即 1×n matmul）。
checkCase :: Bool -> Context -> ([Int], [Int]) -> IO ()
checkCase avx ctx (ws, xs) = do
  let n = length ws
      hsRef = foldl gf27Add 0 (zipWith gf27Mul ws xs)          -- ① Haskell 标量
  cScalar <- gf27RowdotScalarOnly ws xs                        -- ② C 标量
  hsRef `shouldBe` cScalar
  when avx $ do
    avxRes <- gf27Rowdot ws xs                                 -- ③ AVX2
    avxRes `shouldBe` hsRef
  -- ④ GPU：复用 matmulWgsl，令 m = 1（第 0 行即行点积）
  let kk = max 1 n
      wBytes = kk * 4
      xBytes = kk * 4
      yBytes = 4
      pad xs' = take kk (xs' ++ repeat 0)
  wb <- newStorageBuffer ctx wBytes
  xb <- newStorageBuffer ctx xBytes
  yb <- newStorageBuffer ctx yBytes
  rb <- newReadBackBuffer ctx yBytes
  dimsBuf <- newStorageBuffer ctx 8
  uploadWords ctx wb (map fromIntegral (pad ws))
  uploadWords ctx xb (map fromIntegral (pad xs))
  uploadWords ctx dimsBuf [1, fromIntegral kk]
  kern <- newKernel ctx matmulWgsl 4 "main"
  got <- runKernel ctx kern [wb, xb, yb, dimsBuf] (1, 1, 1) (Just (yb, rb, 1))
  (case got of (v : _) -> fromIntegral v; [] -> -1) `shouldBe` hsRef

matmulWgsl :: String
matmulWgsl =
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
    , "@group(0) @binding(0) var<storage, read_write> wv: array<u32>;"
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
