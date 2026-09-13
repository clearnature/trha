{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE ForeignFunctionInterface #-}

-- | wgpu-native C API 的**真实符号**绑定（W3）。
--
-- == 与旧 @Infrastructure.WebGPU.FFI@ 的区别
--
-- 旧文件声明的 @webgpu_create_device@ 之类符号**在真实库里一个都不存在**
-- （@nm -D libwgpu_native.so@ 实测出现 0 次），是编造的占位；本模块按
-- @3rdparty\/wgpu-native\/include\/webgpu\/webgpu.h@（v29.0.1.1）的真实签名绑定，
-- 并返回 'Infrastructure.WebGPU.Raw.Types' 的**强类型句柄**而非裸 @Ptr ()@。
--
-- == 两段式：raw + 强类型外壳
--
-- @foreign import@ 的参数/返回类型必须是 FFI 可表示类型（@Ptr a@），因此每个函数先绑
-- 一个 @raw*@ 版本（句柄用 @Ptr XOD@ —— 正好是 'toPtr' \/ 'fromPtr' 的载体类型），
-- 再用它们包一层强类型外壳。错用会被类型系统拦住，FFI 边界保持标准。
--
-- == 异步三处暂缺（adapter / device / buffer-map）
--
-- 它们的 @*CallbackInfo@ 要求一个函数指针，其**按值** @WGPUStringView@ 参数
-- 无法用 Haskell FFI 表达（Haskell FFI 不支持按值传 struct）。且 v29 里
-- adapter\/device 句柄**只能经 callback 取得**（@WGPUFutureWaitInfo@ 只有
-- @{future, completed}@，不含结果）。因此这三处需要一个 C shim
-- （@cbits\/wgpu_callback_shim.c@：把按值 struct 转成指针再回调 Haskell）——
-- 见 @docs\/plans\/webgpu-wiring-plan.md@ 的 W3 备注。
module Infrastructure.WebGPU.Raw.FFI
  ( -- * 实例
    createInstance
    -- * 设备 → 队列
  , getQueue
    -- * 缓冲
  , createBuffer
  , queueWriteBuffer
  , bufferGetMappedRange
  , bufferUnmap
    -- * Shader / 管线 / bind group
  , createShaderModule
  , createBindGroupLayout
  , createPipelineLayout
  , createComputePipeline
  , createBindGroup
    -- * 命令编码与提交
  , createCommandEncoder
  , beginComputePass
  , setPipeline
  , setBindGroup
  , dispatchWorkgroups
  , endComputePass
  , finishCommandEncoder
  , queueSubmit
  ) where


import Data.Word (Word32, Word64)
import Foreign.C.Types (CSize (..))
import Foreign.Ptr (Ptr, nullPtr)

import Infrastructure.WebGPU.Raw.Structs
  ( BindGroupDescriptor
  , BindGroupLayoutDescriptor
  , BufferDescriptor
  , ComputePipelineDescriptor
  , PipelineLayoutDescriptor
  , ShaderModuleDescriptor
  )
import Infrastructure.WebGPU.Raw.Types
  ( BindGroup
  , BindGroupLayout
  , Buffer
  , CommandEncoder
  , ComputePassEncoder
  , ComputePipeline
  , Device
  , Instance
  , PipelineLayout
  , Queue
  , ShaderModule
  , BindGroupLayoutOD
  , BindGroupOD
  , BufferOD
  , CommandEncoderOD
  , ComputePassEncoderOD
  , ComputePipelineOD
  , DeviceOD
  , InstanceOD
  , PipelineLayoutOD
  , QueueOD
  , ShaderModuleOD
  , fromPtr
  , toPtr
  )

-- ---------------------------------------------------------------------------
-- 实例
-- ---------------------------------------------------------------------------

-- | @WGPUInstance wgpuCreateInstance(WGPUInstanceDescriptor const*)@。
-- 传 @NULL@ 表示用默认描述符。
foreign import ccall unsafe "wgpuCreateInstance"
  rawCreateInstance :: Ptr () -> IO (Ptr InstanceOD)

-- | 创建实例（默认描述符）。
createInstance :: IO Instance
createInstance = fromPtr <$> rawCreateInstance nullPtr

-- ---------------------------------------------------------------------------
-- 设备 → 队列
-- ---------------------------------------------------------------------------

-- | @WGPUQueue wgpuDeviceGetQueue(WGPUDevice)@ —— Queue 由 Device 派生。
foreign import ccall unsafe "wgpuDeviceGetQueue"
  rawGetQueue :: Ptr DeviceOD -> IO (Ptr QueueOD)

-- | 取设备的队列。
getQueue :: Device -> IO Queue
getQueue d = fromPtr <$> rawGetQueue (toPtr d)

-- ---------------------------------------------------------------------------
-- 缓冲
-- ---------------------------------------------------------------------------

-- | @WGPUBuffer wgpuDeviceCreateBuffer(WGPUDevice, WGPUBufferDescriptor const*)@。
foreign import ccall unsafe "wgpuDeviceCreateBuffer"
  rawCreateBuffer :: Ptr DeviceOD -> Ptr BufferDescriptor -> IO (Ptr BufferOD)

-- | 创建缓冲。失败时返回 'nullHandle'（对应 C 的 @WGPU_NULLABLE@）。
createBuffer :: Device -> Ptr BufferDescriptor -> IO Buffer
createBuffer d desc = fromPtr <$> rawCreateBuffer (toPtr d) desc

-- | @void wgpuQueueWriteBuffer(WGPUQueue, WGPUBuffer, uint64_t, void const*, size_t)@。
foreign import ccall unsafe "wgpuQueueWriteBuffer"
  queueWriteBuffer :: Ptr QueueOD -> Ptr BufferOD -> Word64 -> Ptr () -> CSize -> IO ()

-- | @void* wgpuBufferGetMappedRange(WGPUBuffer, size_t, size_t)@。
foreign import ccall unsafe "wgpuBufferGetMappedRange"
  bufferGetMappedRange :: Ptr BufferOD -> CSize -> CSize -> IO (Ptr ())

-- | @void wgpuBufferUnmap(WGPUBuffer)@。
foreign import ccall unsafe "wgpuBufferUnmap"
  bufferUnmap :: Ptr BufferOD -> IO ()

-- ---------------------------------------------------------------------------
-- Shader / 管线 / bind group
-- ---------------------------------------------------------------------------

-- | @WGPUShaderModule wgpuDeviceCreateShaderModule(WGPUDevice, WGPUShaderModuleDescriptor const*)@。
foreign import ccall unsafe "wgpuDeviceCreateShaderModule"
  rawCreateShaderModule :: Ptr DeviceOD -> Ptr ShaderModuleDescriptor -> IO (Ptr ShaderModuleOD)

-- | 由 WGSL 源创建 shader 模块（WGSL 经描述符的 @nextInChain@ 传入）。
createShaderModule :: Device -> Ptr ShaderModuleDescriptor -> IO ShaderModule
createShaderModule d desc = fromPtr <$> rawCreateShaderModule (toPtr d) desc

-- | @WGPUBindGroupLayout wgpuDeviceCreateBindGroupLayout(WGPUDevice, WGPUBindGroupLayoutDescriptor const*)@。
foreign import ccall unsafe "wgpuDeviceCreateBindGroupLayout"
  rawCreateBindGroupLayout :: Ptr DeviceOD -> Ptr BindGroupLayoutDescriptor -> IO (Ptr BindGroupLayoutOD)

-- | 创建 bind group layout。
createBindGroupLayout :: Device -> Ptr BindGroupLayoutDescriptor -> IO BindGroupLayout
createBindGroupLayout d desc = fromPtr <$> rawCreateBindGroupLayout (toPtr d) desc

-- | @WGPUPipelineLayout wgpuDeviceCreatePipelineLayout(WGPUDevice, WGPUPipelineLayoutDescriptor const*)@。
foreign import ccall unsafe "wgpuDeviceCreatePipelineLayout"
  rawCreatePipelineLayout :: Ptr DeviceOD -> Ptr PipelineLayoutDescriptor -> IO (Ptr PipelineLayoutOD)

-- | 创建管线布局。
createPipelineLayout :: Device -> Ptr PipelineLayoutDescriptor -> IO PipelineLayout
createPipelineLayout d desc = fromPtr <$> rawCreatePipelineLayout (toPtr d) desc

-- | @WGPUComputePipeline wgpuDeviceCreateComputePipeline(WGPUDevice, WGPUComputePipelineDescriptor const*)@。
foreign import ccall unsafe "wgpuDeviceCreateComputePipeline"
  rawCreateComputePipeline :: Ptr DeviceOD -> Ptr ComputePipelineDescriptor -> IO (Ptr ComputePipelineOD)

-- | 创建计算管线。
createComputePipeline :: Device -> Ptr ComputePipelineDescriptor -> IO ComputePipeline
createComputePipeline d desc = fromPtr <$> rawCreateComputePipeline (toPtr d) desc

-- | @WGPUBindGroup wgpuDeviceCreateBindGroup(WGPUDevice, WGPUBindGroupDescriptor const*)@。
foreign import ccall unsafe "wgpuDeviceCreateBindGroup"
  rawCreateBindGroup :: Ptr DeviceOD -> Ptr BindGroupDescriptor -> IO (Ptr BindGroupOD)

-- | 创建 bind group。
createBindGroup :: Device -> Ptr BindGroupDescriptor -> IO BindGroup
createBindGroup d desc = fromPtr <$> rawCreateBindGroup (toPtr d) desc

-- ---------------------------------------------------------------------------
-- 命令编码与提交
-- ---------------------------------------------------------------------------

-- | @WGPUCommandEncoder wgpuDeviceCreateCommandEncoder(WGPUDevice, WGPU_NULLABLE WGPUCommandEncoderDescriptor const*)@。
foreign import ccall unsafe "wgpuDeviceCreateCommandEncoder"
  rawCreateCommandEncoder :: Ptr DeviceOD -> Ptr () -> IO (Ptr CommandEncoderOD)

-- | 创建命令编码器（传 @NULL@ 描述符用默认值）。
createCommandEncoder :: Device -> IO CommandEncoder
createCommandEncoder d = fromPtr <$> rawCreateCommandEncoder (toPtr d) nullPtr

-- | @WGPUComputePassEncoder wgpuCommandEncoderBeginComputePass(WGPUCommandEncoder, WGPU_NULLABLE WGPUComputePassDescriptor const*)@。
foreign import ccall unsafe "wgpuCommandEncoderBeginComputePass"
  rawBeginComputePass :: Ptr CommandEncoderOD -> Ptr () -> IO (Ptr ComputePassEncoderOD)

-- | 开启计算通道（传 @NULL@ 描述符用默认值）。
beginComputePass :: CommandEncoder -> IO ComputePassEncoder
beginComputePass e = fromPtr <$> rawBeginComputePass (toPtr e) nullPtr

-- | @void wgpuComputePassEncoderSetPipeline(WGPUComputePassEncoder, WGPUComputePipeline)@。
foreign import ccall unsafe "wgpuComputePassEncoderSetPipeline"
  setPipeline :: Ptr ComputePassEncoderOD -> Ptr ComputePipelineOD -> IO ()

-- | @void wgpuComputePassEncoderSetBindGroup(WGPUComputePassEncoder, uint32_t, WGPU_NULLABLE WGPUBindGroup, size_t, uint32_t const*)@。
foreign import ccall unsafe "wgpuComputePassEncoderSetBindGroup"
  setBindGroup :: Ptr ComputePassEncoderOD -> Word32 -> Ptr BindGroupOD -> CSize -> Ptr Word32 -> IO ()

-- | @void wgpuComputePassEncoderDispatchWorkgroups(WGPUComputePassEncoder, uint32_t, uint32_t, uint32_t)@。
foreign import ccall unsafe "wgpuComputePassEncoderDispatchWorkgroups"
  dispatchWorkgroups :: Ptr ComputePassEncoderOD -> Word32 -> Word32 -> Word32 -> IO ()

-- | @void wgpuComputePassEncoderEnd(WGPUComputePassEncoder)@。
foreign import ccall unsafe "wgpuComputePassEncoderEnd"
  endComputePass :: Ptr ComputePassEncoderOD -> IO ()

-- | @WGPUCommandBuffer wgpuCommandEncoderFinish(WGPUCommandEncoder, WGPU_NULLABLE WGPUCommandBufferDescriptor const*)@。
--
-- 命令缓冲在 Haskell 侧不建模（只提交一次、随即由 wgpu 回收），故给裸指针。
foreign import ccall unsafe "wgpuCommandEncoderFinish"
  finishCommandEncoder :: Ptr CommandEncoderOD -> Ptr () -> IO (Ptr ())

-- | @void wgpuQueueSubmit(WGPUQueue, size_t, WGPUCommandBuffer const*)@。
foreign import ccall unsafe "wgpuQueueSubmit"
  queueSubmit :: Ptr QueueOD -> CSize -> Ptr (Ptr ()) -> IO ()
