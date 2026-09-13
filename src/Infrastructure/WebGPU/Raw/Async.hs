{-# LANGUAGE ForeignFunctionInterface #-}

-- | WebGPU 异步入口的**同步外壳**（W3 异步部分）。
--
-- v29 里三处入口是异步的（返回 WGPUFuture 并收 *CallbackInfo）：
-- wgpuInstanceRequestAdapter / wgpuAdapterRequestDevice / wgpuBufferMapAsync。
--
-- 实现方式与常见教程不同，原因见 @cbits/wgpu_callback_shim.c@ 的长注释：
--   * v29 的 wgpuInstanceWaitAny **未实现**（会 panic），所以不能"发起 → WaitAny → 取结果"；
--   * 让 C 回调直接进 Haskell 会死锁（回调在 ProcessEvents 的调用线程上同步触发，
--     该线程正处在 FFI 栈里，拿不到 RTS 锁）。
--
-- 因此改为：**C shim 把结果放进槽位，Haskell 轮询槽位**。跨语言只有标量/指针，
-- 既没有按值 struct，也没有回调重入。
module Infrastructure.WebGPU.Raw.Async
  ( requestAdapterSync
  , requestDeviceSync
  , bufferMapSync
  ) where

import Control.Concurrent (threadDelay)
import Data.Word (Word64)
import Foreign.C.Types (CInt (..), CSize (..))
import Foreign.Ptr (Ptr, castPtr, nullPtr)

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
-- C shim 入口（无回调跨界）
-- ---------------------------------------------------------------------------

foreign import ccall safe "trha_wgpu_request_adapter"
  cRequestAdapter :: Ptr InstanceOD -> Ptr RequestAdapterOptions -> IO ()

foreign import ccall safe "trha_wgpu_request_device"
  cRequestDevice :: Ptr AdapterOD -> Ptr () -> IO ()

foreign import ccall safe "trha_wgpu_buffer_map"
  cBufferMap :: Ptr BufferOD -> Word64 -> CSize -> CSize -> IO ()

-- | 事件泵（safe：它会驱动 wgpu 的进度，可能耗时）。
foreign import ccall safe "trha_wgpu_process_events"
  cProcessEvents :: Ptr InstanceOD -> IO ()

foreign import ccall unsafe "trha_wgpu_poll"
  cPoll :: IO CInt

foreign import ccall unsafe "trha_wgpu_last_status"
  cLastStatus :: IO CInt

foreign import ccall unsafe "trha_wgpu_last_object"
  cLastObject :: IO (Ptr ())

-- | 轮询直到 shim 槽位就绪（其间持续泵事件并让出 CPU）。
waitDone :: Instance -> IO ()
waitDone inst = go
  where
    go = do
      d <- cPoll
      if d /= 0
        then pure ()
        else cProcessEvents (toPtr inst) >> threadDelay 1000 >> go

-- | 请求适配器（同步外观）。失败时返回 @Left 状态码@。
requestAdapterSync :: Instance -> Ptr RequestAdapterOptions -> IO (Either CInt Adapter)
requestAdapterSync inst opts = do
  cRequestAdapter (toPtr inst) opts
  waitDone inst
  st <- cLastStatus
  obj <- cLastObject
  if st == 0 && obj /= nullPtr
    then pure (Right (fromPtr (castPtr obj)))
    else pure (Left st)

-- | 请求设备（同步外观）。@descriptor@ 可为 @NULL@。
requestDeviceSync :: Instance -> Adapter -> Ptr () -> IO (Either CInt Device)
requestDeviceSync inst adptr desc = do
  cRequestDevice (toPtr adptr) desc
  waitDone inst
  st <- cLastStatus
  obj <- cLastObject
  if st == 0 && obj /= nullPtr
    then pure (Right (fromPtr (castPtr obj)))
    else pure (Left st)

-- | 映射缓冲（同步外观）。@mode@ 用 'Infrastructure.WebGPU.Raw.Enums.mapModeToRaw'
-- 取的原始值；成功后自行 @bufferGetMappedRange@ / @bufferUnmap@。
bufferMapSync :: Instance -> Buffer -> Word64 -> CSize -> CSize -> IO (Either CInt ())
bufferMapSync inst buf mode off sz = do
  cBufferMap (toPtr buf) mode off sz
  waitDone inst
  st <- cLastStatus
  if st == 0 then pure (Right ()) else pure (Left st)
