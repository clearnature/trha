{-# LANGUAGE OverloadedStrings #-}

-- | WebGPU 计算的功能性验证：在真实 GPU 上跑一个 WGSL compute kernel，
-- 把结果与 CPU 逐元素比对。
--
-- 为什么要有这个测试：@webgpu-wiring-plan.md@ §0 的第二条判据就是「GPU 结果
-- 与 CPU 版逐元素一致」。只验证「能编译/能链接」是不够的——本项目曾经出现过
-- pipeline 创建失败被静默吞掉、直到 queueSubmit 才以 Rust panic 炸出来的情况。
--
-- **无 GPU 时挂起而非失败**：GitHub Actions 的 runner 没有真实 GPU（只有
-- llvmpipe/WARP 软件光栅器），此时 @createContext@ 会失败，测试报 pending。
-- 有 GPU 的机器（开发机、自托管 runner）则严格验证。
module Main (main) where

import Data.Word (Word32)
import Test.Hspec

import Infrastructure.WebGPU.Buffer (newReadBackBuffer, newStorageBuffer, readWords, uploadWords)
import Infrastructure.WebGPU.Context (createContext)
import Infrastructure.WebGPU.Kernel (newKernel, runKernel)

-- | 每个元素 +1。两个 binding 都是 storage：@newKernel@ 给所有 binding 建的是
-- 读写 layout（@Storage { access: LOAD | STORE }@），所以 shader 侧必须写
-- @read_write@，否则 wgpu 会以「Storage class ... doesn't match」拒绝创建 pipeline。
wgslIncrement :: String
wgslIncrement = unlines
  [ "@group(0) @binding(0) var<storage, read_write> a: array<u32>;"
  , "@group(0) @binding(1) var<storage, read_write> b: array<u32>;"
  , "@compute @workgroup_size(64)"
  , "fn main(@builtin(global_invocation_id) gid: vec3<u32>) {"
  , "  let i = gid.x;"
  , "  if (i < arrayLength(&a)) { b[i] = a[i] + 1u; }"
  , "}"
  ]

main :: IO ()
main = hspec $ describe "WebGPU compute" $ do
  it "在 GPU 上给 64 个元素各 +1，结果与 CPU 一致" $ do
    r <- createContext
    case r of
      Left e -> pendingWith ("no usable GPU context: " <> e)
      Right ctx -> do
        let n = 64
            input = [0 .. fromIntegral n - 1] :: [Word32]
            want = map (+ 1) input
        inBuf <- newStorageBuffer ctx (n * 4)
        outBuf <- newStorageBuffer ctx (n * 4)
        rb <- newReadBackBuffer ctx (n * 4)
        uploadWords ctx inBuf input
        k <- newKernel ctx wgslIncrement 2 "main"
        got <- runKernel ctx k [inBuf, outBuf] (1, 1, 1) (Just (outBuf, rb, n))
        got `shouldBe` want
