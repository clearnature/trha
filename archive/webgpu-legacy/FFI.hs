{-# LANGUAGE ForeignFunctionInterface #-}

module Infrastructure.WebGPU.FFI
  ( -- * FFI Bindings
    webgpuCreateDevice
  , webgpuCreateBuffer
  , webgpuCreateShaderModule
  , webgpuCreateComputePipeline
  , webgpuBeginComputePass
  , webgpuSetPipeline
  , webgpuSetBindGroup
  , webgpuDispatchWorkgroups
  , webgpuEndComputePass
  , webgpuFinishCommandEncoder
  , webgpuSubmitCommandBuffer
  ) where

import Foreign.C.Types
import Foreign.Ptr
import Foreign.Storable
import Data.Text (Text)
import qualified Data.Text.Foreign as TF

-- | FFI bindings to WebGPU
-- These are actual C bindings to the WebGPU API
-- In production, these would link to wgpu-native or similar

-- | Create a WebGPU device
foreign import ccall "webgpu_create_device"
  webgpuCreateDevice :: Ptr () -> IO (Ptr ())

-- | Create a WebGPU buffer
foreign import ccall "webgpu_create_buffer"
  webgpuCreateBuffer :: Ptr () -> CSize -> CUInt -> IO (Ptr ())

-- | Create a WebGPU shader module
foreign import ccall "webgpu_create_shader_module"
  webgpuCreateShaderModule :: Ptr () -> Ptr CChar -> CSize -> IO (Ptr ())

-- | Create a WebGPU compute pipeline
foreign import ccall "webgpu_create_compute_pipeline"
  webgpuCreateComputePipeline :: Ptr () -> Ptr () -> Ptr () -> IO (Ptr ())

-- | Begin a WebGPU compute pass
foreign import ccall "webgpu_begin_compute_pass"
  webgpuBeginComputePass :: Ptr () -> IO (Ptr ())

-- | Set WebGPU pipeline
foreign import ccall "webgpu_set_pipeline"
  webgpuSetPipeline :: Ptr () -> Ptr () -> IO ()

-- | Set WebGPU bind group
foreign import ccall "webgpu_set_bind_group"
  webgpuSetBindGroup :: Ptr () -> CUInt -> Ptr () -> IO ()

-- | Dispatch WebGPU workgroups
foreign import ccall "webgpu_dispatch_workgroups"
  webgpuDispatchWorkgroups :: Ptr () -> CUInt -> CUInt -> CUInt -> IO ()

-- | End WebGPU compute pass
foreign import ccall "webgpu_end_compute_pass"
  webgpuEndComputePass :: Ptr () -> IO ()

-- | Finish WebGPU command encoder
foreign import ccall "webgpu_finish_command_encoder"
  webgpuFinishCommandEncoder :: Ptr () -> IO (Ptr ())

-- | Submit WebGPU command buffer
foreign import ccall "webgpu_submit_command_buffer"
  webgpuSubmitCommandBuffer :: Ptr () -> Ptr () -> IO ()