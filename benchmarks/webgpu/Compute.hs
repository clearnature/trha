-- | hello-compute（高层 API 版）：输入 [1,2,3,4] → GPU 逐元素平方 → [1,4,9,16]。
--
-- 与上一版（直接调 Raw/**，231 行）相比，这里只描述"要算什么"：描述符、
-- 指针偏移、事件泵、buffer usage 的组合都收进了 Context/Buffer/Kernel。
module Main (main) where

import Data.Word (Word32)

import Infrastructure.WebGPU.Buffer (newReadBackBuffer, newStorageBuffer, uploadWords)
import Infrastructure.WebGPU.Context (withContext)
import Infrastructure.WebGPU.Kernel (newKernel, runKernel)

inputData :: [Word32]
inputData = [1, 2, 3, 4]

expected :: [Word32]
expected = map (\x -> x * x) inputData

dataBytes :: Int
dataBytes = length inputData * 4

wgsl :: String
wgsl = unlines
  [ "@group(0) @binding(0) var<storage, read_write> inp: array<u32>;"
  , "@group(0) @binding(1) var<storage, read_write> outp: array<u32>;"
  , "@compute @workgroup_size(4)"
  , "fn main(@builtin(global_invocation_id) gid: vec3<u32>) {"
  , "  let i = gid.x;"
  , "  outp[i] = inp[i] * inp[i];"
  , "}"
  ]

main :: IO ()
main = withContext $ \ctx -> do
  putStrLn "=== WebGPU hello-compute（高层 API 版）==="
  putStrLn ("输入: " ++ show inputData)
  putStrLn ("期望: " ++ show expected)

  inBuf <- newStorageBuffer ctx dataBytes
  uploadWords ctx inBuf inputData
  outBuf <- newStorageBuffer ctx dataBytes
  readBack <- newReadBackBuffer ctx dataBytes

  k <- newKernel ctx wgsl 2 "main"
  got <- runKernel ctx k [inBuf, outBuf] (1, 1, 1) (Just (outBuf, readBack, length inputData))

  putStrLn ("实际: " ++ show got)
  if got == expected
    then putStrLn "\n✓ GPU 结果与 CPU 参考答案逐元素一致 —— hello-compute 通过"
    else putStrLn "\n✗ 结果不一致"
