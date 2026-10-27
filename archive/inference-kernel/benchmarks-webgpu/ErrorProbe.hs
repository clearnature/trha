{-# LANGUAGE ScopedTypeVariables #-}

-- | 错误捕获探针：故意制造一次 WebGPU 校验错误，验证它**不再 abort 进程**。
--
-- 违规点：MAP_READ 只能与 COPY_DST 搭配、不能叠加 STORAGE —— 正是 W6 阶段踩过的那个。
-- 装上 uncaptured error 回调之前，这次调用会让 wgpu-native 的默认处理器 panic、
-- 进程 abort（RUN_EXIT=134）；装上之后应当变成可查询的错误。
module Main (main) where

import Foreign.Marshal.Alloc (allocaBytes)
import Foreign.Marshal.Utils (fillBytes)
import Foreign.Ptr (nullPtr)
import Foreign.Storable (poke)

import Infrastructure.WebGPU.Context (Context (..), withContext)
import Infrastructure.WebGPU.Error (GpuError (..), errorTypeName, lastError)
import Infrastructure.WebGPU.Raw.Enums (bufferUsageMapRead, bufferUsageStorage)
import Infrastructure.WebGPU.Raw.FFI (createBuffer)
import Infrastructure.WebGPU.Raw.Structs (BufferDescriptor (..), StringView (..))

main :: IO ()
main = withContext $ \ctx -> do
  putStrLn "=== WebGPU 错误捕获探针 ==="
  putStrLn "制造违规：buffer usage = MapRead | Storage（WebGPU 不允许 MAP 叠加 STORAGE）"
  _ <- allocaBytes 256 $ \p -> do
    fillBytes p 0 256
    poke
      p
      BufferDescriptor
        { bdNextInChain = nullPtr
        , bdLabel = StringView nullPtr 0
        , bdUsage = bufferUsageMapRead <> bufferUsageStorage
        , bdSize = 64
        , bdMappedAtCreation = 0
        }
    createBuffer (ctxDevice ctx) p
  err <- lastError
  case err of
    Nothing -> putStrLn "✗ 没捕获到错误（不符预期）"
    Just e -> do
      putStrLn ("✓ 已捕获错误，类型 = " ++ errorTypeName (geType e))
      putStrLn ("  消息: " ++ take 240 (geMessage e))
