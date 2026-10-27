{-# LANGUAGE ScopedTypeVariables #-}

-- | C2 负面用例 3：WebGPU 句柄不可混用 —— Device 不能当作 Buffer。
--
-- 预期：**编译失败**。这是 Raw/Types.hs 里"每个对象一个不透明标签"的意义所在：
-- 裸 Ptr () 下 Device/Buffer/Queue 可任意互传，错用只在运行时段错误暴露。
module Main (main) where

import Foreign.Ptr (Ptr)
import Infrastructure.WebGPU.Raw.Types (BufferOD, Device, toPtr)

bad :: Ptr BufferOD
bad = toPtr (undefined :: Device)

main :: IO ()
main = pure ()
