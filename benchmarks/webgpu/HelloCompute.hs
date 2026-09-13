-- | WebGPU 真机探针（阶段一）：走通初始化链
--
-- @Instance → (异步) Adapter → (异步) Device → Queue@
--
-- 这一阶段专门验证三件事是否都成立：
--   1. Raw/FFI.hs 的 wgpu-native 真实符号能链接并解析；
--   2. C shim 的按值 WGPUStringView 蹦床可用；
--   3. Raw/Async.hs 的「回调写 MVar + wgpuInstanceWaitAny 阻塞取回」异步桥接可用。
--
-- 三处都通过后，阶段二再加 buffer / WGSL 管线 / dispatch / 映射读回，做 hello-compute。
--
-- 运行：cabal run trha-webgpu-hello
module Main (main) where

import Control.Monad (when)
import Foreign.Marshal.Alloc (allocaBytes)
import Foreign.Ptr (nullPtr)
import Foreign.Storable (poke)

import Infrastructure.WebGPU.Raw.Async (requestAdapterSync, requestDeviceSync)
import Infrastructure.WebGPU.Raw.Enums (FeatureLevel (..), PowerPreference (..))
import Infrastructure.WebGPU.Raw.FFI (createInstance, getQueue)
import Infrastructure.WebGPU.Raw.Structs (RequestAdapterOptions (..))
import Infrastructure.WebGPU.Raw.Types (isNullHandle)

main :: IO ()
main = do
  putStrLn "=== WebGPU 初始化链探针 ==="

  inst <- createInstance
  putStrLn ("1. wgpuCreateInstance      : " ++ ok (not (isNullHandle inst)))

  -- 适配器：本机有 libvulkan，用默认选项（让 wgpu 自己挑后端）
  adapter <- allocaBytes 64 $ \optsPtr -> do
    poke
      optsPtr
      RequestAdapterOptions
        { raoNextInChain = nullPtr
        , raoFeatureLevel = FeatureLevelCore
        , raoPowerPreference = PowerPreferenceHighPerformance
        , raoForceFallbackAdapter = 0
        , raoBackendType = 0 -- WGPUBackendType_Undefined：不锁定后端
        , raoCompatibleSurface = nullPtr
        }
    requestAdapterSync inst optsPtr

  case adapter of
    Left st -> do
      putStrLn ("2. wgpuInstanceRequestAdapter: 失败（status=" ++ show st ++ "）")
      putStrLn "   → 若为 0 且 message 提示无适配器，检查 Vulkan 驱动 (libvulkan.so.1)"
    Right ad -> do
      putStrLn ("2. wgpuInstanceRequestAdapter: " ++ ok True)

      dev <- requestDeviceSync inst ad nullPtr
      case dev of
        Left st -> putStrLn ("3. wgpuAdapterRequestDevice : 失败（status=" ++ show st ++ "）")
        Right d -> do
          putStrLn ("3. wgpuAdapterRequestDevice : " ++ ok True)
          q <- getQueue d
          putStrLn ("4. wgpuDeviceGetQueue      : " ++ ok (not (isNullHandle q)))
          when (not (isNullHandle q)) $
            putStrLn "\n初始化链全部通过 ✓ —— 可以进入阶段二（hello-compute）"
  where
    ok True = "OK ✓"
    ok False = "返回空句柄 ✗"
