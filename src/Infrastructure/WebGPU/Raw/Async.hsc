{-# LANGUAGE ForeignFunctionInterface #-}

-- | WebGPU 异步入口的**同步外壳**（W3 的异步部分）。
--
-- v29 里三处入口是异步的（返回 @WGPUFuture@ 并收 @*CallbackInfo@）：
--
-- * @wgpuInstanceRequestAdapter@ —— 取 Adapter
-- * @wgpuAdapterRequestDevice@   —— 取 Device
-- * @wgpuBufferMapAsync@         —— 映射缓冲以读写
--
-- 而且 adapter/device 句柄**只能经回调取得**（@WGPUFutureWaitInfo@ 只有
-- @{future, completed}@，不含结果）。本模块把"发起 → 阻塞等待 → 取结果"封成
-- 同步函数：回调写 'MVar'，主线程用 @wgpuInstanceWaitAny@（经 C shim）等它。
--
-- 回调本身由 @cbits\/wgpu_callback_shim.c@ 承载 —— 因为 WebGPU 回调的第二个参数是
-- **按值** @WGPUStringView@，Haskell FFI 无法表达；shim 把它拆成 (指针, 长度)，
-- 于是这里拿到的全是标量。回调模式固定 @WaitAnyOnly@：只在 WaitAny 里触发，
-- 单线程下时序确定。
module Infrastructure.WebGPU.Raw.Async
  ( -- * 同步外壳
    requestAdapterSync
  , requestDeviceSync
  , bufferMapSync
    -- * 回调类型（需要自定义时可复用）
  , BufferMapCb
  , RequestAdapterCb
  , RequestDeviceCb
  , mkBufferMapCb
  , mkRequestAdapterCb
  , mkRequestDeviceCb
  ) where

#include <webgpu/webgpu.h>

import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Data.Word (Word64)
import Foreign.C.Types (CChar, CInt (..), CSize (..))
import Foreign.Ptr (FunPtr, Ptr, freeHaskellFunPtr, nullPtr)

import Infrastructure.WebGPU.Raw.Structs (RequestAdapterOptions)
import Infrastructure.WebGPU.Raw.Types
  ( Adapter
  , AdapterOD
  , Buffer
  , BufferOD
  , Device
  , DeviceOD
  , Instance
  , InstanceOD
  , fromPtr
  , toPtr
  )

-- ---------------------------------------------------------------------------
-- 回调类型（与 cbits/wgpu_callback_shim.c 里的 trha_*_cb 一一对应）
-- ---------------------------------------------------------------------------

-- | buffer 映射回调：@(status, msgPtr, msgLen, userdata)@。
type BufferMapCb = FunPtr (CInt -> Ptr CChar -> CSize -> Ptr () -> IO ())

-- | requestAdapter 回调：额外带一个 Adapter 句柄（成功时非空）。
type RequestAdapterCb = FunPtr (CInt -> Ptr AdapterOD -> Ptr CChar -> CSize -> Ptr () -> IO ())

-- | requestDevice 回调：额外带一个 Device 句柄（成功时非空）。
type RequestDeviceCb = FunPtr (CInt -> Ptr DeviceOD -> Ptr CChar -> CSize -> Ptr () -> IO ())

-- | 把 Haskell 函数包成可传给 C 的函数指针。
foreign import ccall "wrapper"
  mkBufferMapCb :: (CInt -> Ptr CChar -> CSize -> Ptr () -> IO ()) -> IO BufferMapCb

-- | 同 'mkBufferMapCb'。
foreign import ccall "wrapper"
  mkRequestAdapterCb
    :: (CInt -> Ptr AdapterOD -> Ptr CChar -> CSize -> Ptr () -> IO ()) -> IO RequestAdapterCb

-- | 同 'mkBufferMapCb'。
foreign import ccall "wrapper"
  mkRequestDeviceCb
    :: (CInt -> Ptr DeviceOD -> Ptr CChar -> CSize -> Ptr () -> IO ()) -> IO RequestDeviceCb

-- ---------------------------------------------------------------------------
-- C shim 入口（返回 future.id，避免按值 struct 跨界）
-- ---------------------------------------------------------------------------

foreign import ccall safe "trha_wgpu_instance_request_adapter"
  cInstanceRequestAdapter
    :: Ptr InstanceOD -> Ptr RequestAdapterOptions -> RequestAdapterCb -> IO Word64

foreign import ccall safe "trha_wgpu_adapter_request_device"
  cAdapterRequestDevice
    :: Ptr AdapterOD -> Ptr () -> RequestDeviceCb -> IO Word64

foreign import ccall safe "trha_wgpu_buffer_map_async"
  cBufferMapAsync
    :: Ptr BufferOD -> Word64 -> CSize -> CSize -> BufferMapCb -> IO Word64

-- | 阻塞等待一个 future（@timeoutNS = maxBound@ 表示不限时）。
-- 用 @safe@ 以免阻塞运行时。
foreign import ccall safe "trha_wgpu_instance_wait_any"
  cInstanceWaitAny :: Ptr InstanceOD -> Word64 -> Word64 -> IO CInt

-- | @WGPUWaitStatus_Success@ 的原始值。
waitStatusSuccess :: CInt
waitStatusSuccess = #{const WGPUWaitStatus_Success}

-- ---------------------------------------------------------------------------
-- 同步外壳
-- ---------------------------------------------------------------------------

-- | 请求适配器（同步外观）。失败时返回 @(Left 错误码)@。
--
-- 用法：@requestAdapterSync inst (castPtr optsPtr)@ —— 注意 @WGPUFuture@ 的
-- @WaitAnyOnly@ 模式要求回调在 @WaitAny@ 内触发，因此这里**先发起、后等待**，
-- 中间不做其它 WebGPU 调用。
requestAdapterSync :: Instance -> Ptr RequestAdapterOptions -> IO (Either CInt Adapter)
requestAdapterSync inst opts = do
  mv <- newEmptyMVar
  cb <-
    mkRequestAdapterCb $ \status adapterPtr _msgPtr _msgLen _ud ->
      putMVar mv (status, adapterPtr)
  _fut <- cInstanceRequestAdapter (toPtr inst) opts cb
  (status, adapterPtr) <- takeMVar mv
  freeHaskellFunPtr cb
  if status == 0 && adapterPtr /= nullPtr
    then pure (Right (fromPtr adapterPtr))
    else pure (Left status)

-- | 请求设备（同步外观）。@descriptor@ 可传 @NULL@ 用默认。
requestDeviceSync :: Instance -> Adapter -> Ptr () -> IO (Either CInt Device)
requestDeviceSync inst adptr desc = do
  mv <- newEmptyMVar
  cb <-
    mkRequestDeviceCb $ \status devicePtr _msgPtr _msgLen _ud ->
      putMVar mv (status, devicePtr)
  _fut <- cAdapterRequestDevice (toPtr adptr) desc cb
  (status, devicePtr) <- takeMVar mv
  freeHaskellFunPtr cb
  if status == 0 && devicePtr /= nullPtr
    then pure (Right (fromPtr devicePtr))
    else pure (Left status)

-- | 映射缓冲（同步外观，读模式见 'Infrastructure.WebGPU.Raw.Enums.mapModeRead'）。
-- 成功后需自行 @bufferGetMappedRange@ 取指针、@bufferUnmap@ 归还。
bufferMapSync :: Instance -> Buffer -> Word64 -> CSize -> CSize -> IO (Either CInt ())
bufferMapSync inst buf mode off sz = do
  mv <- newEmptyMVar
  cb <- mkBufferMapCb $ \status _msgPtr _msgLen _ud -> putMVar mv status
  _fut <- cBufferMapAsync (toPtr buf) mode off sz cb
  status <- takeMVar mv
  freeHaskellFunPtr cb
  if status == 0
    then pure (Right ())
    else pure (Left status)
