{-# LANGUAGE ScopedTypeVariables #-}

-- | WebGPU 上下文：@instance → adapter → device → queue@ 的生命周期。
--
-- 这是"高层"的第一块：把 @Raw/**@ 里那串初始化（含两处异步）收成一个值。
-- 所有低层细节（异步槽位轮询、描述符清零、v29 的 Status 归一化）都在
-- @Raw\/Async.hs@ 与 C shim 里，这里只见强类型句柄。
module Infrastructure.WebGPU.Context
  ( Context (..)
  , createContext
  , withContext
  ) where

import Foreign.C.Types (CSize (..))
import Foreign.Marshal.Alloc (allocaBytes)
import Foreign.Marshal.Utils (fillBytes)
import Foreign.Ptr (Ptr, castPtr, nullPtr)
import Foreign.Storable (poke)

import Infrastructure.WebGPU.Raw.Async (requestAdapterSync, requestDeviceSync)
import Infrastructure.WebGPU.Raw.Enums (FeatureLevel (..), PowerPreference (..))
import Infrastructure.WebGPU.Raw.FFI (createInstance, getQueue)
import Infrastructure.WebGPU.Raw.Structs (RequestAdapterOptions (..))
import Infrastructure.WebGPU.Raw.Types (Adapter, Device, Instance, Queue)

-- | device descriptor 的大小（由 C shim 提供，免得在 Haskell 侧猜结构尺寸）。
foreign import ccall unsafe "trha_wgpu_device_descriptor_size"
  cDeviceDescriptorSize :: IO CSize

-- | 由 C shim 初始化一个 @WGPUDeviceDescriptor@（含**我们的 uncaptured error 回调**）。
--
-- 为什么让 C 来填：该结构含内嵌的 @WGPUQueueDescriptor@ 与两个 callbackInfo，
-- 在 Haskell 侧逐字段构造既冗长又易错位；而装上自己的错误回调是必须的 ——
-- 否则 wgpu-native 的默认处理器遇到校验错误会直接 abort 进程。
foreign import ccall unsafe "trha_wgpu_device_descriptor_init"
  cDeviceDescriptorInit :: Ptr () -> IO ()

-- | 一个可用的 WebGPU 上下文。
data Context = Context
  { ctxInstance :: Instance
  , ctxAdapter :: Adapter
  , ctxDevice :: Device
  , ctxQueue :: Queue
  }

-- | 建立上下文：默认描述符建 instance，@FeatureLevelCore@ + 高性能偏好选 adapter
-- （@backendType = 0@ 即 Undefined，让 wgpu 自选；本机走 Vulkan）。
createContext :: IO (Either String Context)
createContext = do
  inst <- createInstance
  adapterE <- allocaBytes 256 $ \p -> do
    fillBytes p 0 256
    poke
      p
      RequestAdapterOptions
        { raoNextInChain = nullPtr
        , raoFeatureLevel = FeatureLevelCore
        , raoPowerPreference = PowerPreferenceHighPerformance
        , raoForceFallbackAdapter = 0
        , raoBackendType = 0
        , raoCompatibleSurface = nullPtr
        }
    requestAdapterSync inst p
  case adapterE of
    Left st -> pure (Left ("requestAdapter 失败, status=" ++ show st))
    Right adapter -> do
      devE <- do
        sz <- cDeviceDescriptorSize
        allocaBytes (max 512 (fromIntegral sz)) $ \descPtr -> do
          cDeviceDescriptorInit (castPtr descPtr)
          requestDeviceSync inst adapter (castPtr descPtr)
      case devE of
        Left st -> pure (Left ("requestDevice 失败, status=" ++ show st))
        Right device -> do
          q <- getQueue device
          pure (Right (Context inst adapter device q))

-- | 括号式使用（创建失败即抛错）。资源释放（release 系列）待补。
withContext :: (Context -> IO a) -> IO a
withContext k = do
  r <- createContext
  case r of
    Left msg -> fail msg
    Right ctx -> k ctx
